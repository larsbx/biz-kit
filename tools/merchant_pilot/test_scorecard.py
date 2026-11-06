import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scorecard import InvalidSnapshot, score

HERE = Path(__file__).resolve().parent


class ScorecardTest(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads((HERE / "synthetic.json").read_text(encoding="utf-8"))

    def test_window_denominators_and_boundary_events(self):
        result = score(self.snapshot)
        self.assertEqual(result["dataset"], "synthetic")
        self.assertEqual(result["demand"], {
            "qualified_requests": 7, "requests_with_accepted_order": 5,
            "seven_day_match": {"numerator": 4, "denominator": 5, "incomplete": 1, "withdrawn_early": 1},
            "first_quote_within_seven_days": {"median_seconds": 129600, "observed": 4, "unmatched_mature": 1},
            "seven_day_invitation_response": {"numerator": 5, "denominator": 6},
        })
        self.assertEqual(result["orders"], {
            "accepted_orders": 5, "realized_orders": 3,
            "on_time_fulfillment": {"numerator": 2, "denominator": 4, "incomplete": 1,
                                    "pending_past_promise": 1},
            "cancelled": {"numerator": 1, "denominator": 4},
            "returns_to_date": {"numerator": 1, "denominator": 3},
            "refunded_orders_to_date": {"numerator": 1, "denominator": 5},
            "intervention_disputes_30_day": {"numerator": 1, "denominator": 3, "incomplete": 2},
            "merchant_repeat_90_day": {"numerator": 1, "denominator": 1, "incomplete": 1},
        })

    def test_margin_reversals_currency_separation_and_sensitivity(self):
        result = score(self.snapshot, include_orders=True)["economics"]
        usd = result["by_currency"]["USD"]
        jpy = result["by_currency"]["JPY"]
        first = result["orders"][0]["roles"]
        # 10,000 gross less 1,000 refunds and 700 net fees leaves 8,300 to the seller.
        self.assertEqual(first["merchant"]["revenue_minor"], 8300)
        self.assertEqual(first["merchant"]["margin_minor"], 1300)
        self.assertEqual(first["servicing_store"]["margin_minor"], 20)
        self.assertEqual(first["platform"]["margin_minor"], 300)
        self.assertEqual(result["orders"][1]["roles"]["platform"]["cost_headroom_minor"], -50)
        self.assertEqual(usd["merchant"]["scenarios"][0]["known_orders_margin_minor"], 2700)
        self.assertIsNone(usd["merchant"]["scenarios"][0]["cohort_margin_minor"])
        self.assertEqual(usd["merchant"]["scenarios"][2]["negative_known_orders"], 3)
        self.assertEqual(usd["servicing_store"]["scenarios"][2]["cohort_margin_minor"], -25)
        self.assertEqual(jpy["merchant"]["missing_inputs"], 1)
        self.assertIsNone(jpy["merchant"]["scenarios"][0]["cohort_margin_minor"])
        self.assertEqual(jpy["platform"]["scenarios"][0]["cohort_margin_minor"], 700)
        self.assertEqual(jpy["platform"]["scenarios"][2]["cohort_margin_minor"], 600)

    def test_full_refund_and_fee_reversals_leave_incurred_costs(self):
        order = self.snapshot["orders"][0]
        order["refunds"][0]["minor"] = 9800
        for fee in order["fees"].values():
            fee["reversed_minor"] = fee["gross_minor"]
        details = score(self.snapshot, include_orders=True)["economics"]["orders"][0]["roles"]
        self.assertEqual({role: row["margin_minor"] for role, row in details.items()},
                         {"merchant": -7000, "servicing_store": -180, "platform": -200})

    def test_missing_fee_affects_only_roles_that_depend_on_it(self):
        self.snapshot["orders"][0]["fees"]["platform"] = None
        roles = score(self.snapshot, include_orders=True)["economics"]["orders"][0]["roles"]
        self.assertEqual(roles["merchant"]["status"], "missing_inputs")
        self.assertEqual(roles["platform"]["status"], "missing_inputs")
        self.assertEqual(roles["servicing_store"]["margin_minor"], 20)

    def test_off_order_costs_with_no_sales_and_unknown_costs(self):
        self.snapshot["orders"] = []
        usd, jpy = self.snapshot["unallocated_costs"]
        jpy["minor"] = None
        result = score(self.snapshot)["economics"]["by_currency"]
        self.assertEqual(result["USD"]["merchant"]["scenarios"][0]["cohort_margin_minor"], -usd["minor"])
        self.assertIsNone(result["JPY"]["platform"]["scenarios"][0]["cohort_margin_minor"])

    def test_empty_input_cohort_has_no_inferred_results(self):
        for key in ("requests", "invitations", "quotes", "orders", "unallocated_costs"):
            self.snapshot[key] = []
        result = score(self.snapshot)
        self.assertIsNone(result["demand"]["first_quote_within_seven_days"]["median_seconds"])
        self.assertEqual(result["orders"]["merchant_repeat_90_day"]["denominator"], 0)
        self.assertEqual(result["economics"]["by_currency"], {})

    def test_aggregate_privacy_and_determinism(self):
        before = score(self.snapshot)
        for key in ("requests", "invitations", "quotes", "orders", "unallocated_costs"):
            self.snapshot[key].reverse()
        self.assertEqual(score(self.snapshot), before)
        report = json.dumps(before)
        self.assertNotIn("orders", before["economics"])
        for collection in ("requests", "quotes", "orders"):
            self.assertNotIn(self.snapshot[collection][0]["id"], report)
        self.assertNotIn(self.snapshot["invitations"][0]["merchant_id"], report)

    def test_sequential_retry_retains_failed_order_and_counts_one_request(self):
        old = self.snapshot["orders"][3]
        quote = dict(self.snapshot["quotes"][5], id="a" * 32, expires_at="2026-01-25T00:00:00Z")
        self.snapshot["quotes"].append(quote)
        retry = dict(old, id="b" * 32, quote_id=quote["id"], accepted_at="2026-01-19T00:00:00Z",
                     outcome="pending", outcome_at=None, reconciled_at=None)
        self.snapshot["orders"].append(retry)
        result = score(self.snapshot)
        self.assertEqual(result["orders"]["accepted_orders"], 6)
        self.assertEqual(result["demand"]["requests_with_accepted_order"], 5)
        retry["accepted_at"] = old["outcome_at"]
        with self.assertRaisesRegex(InvalidSnapshot, "overlapping"):
            score(self.snapshot)

    def test_refuses_acceptance_at_withdrawal_or_expiry(self):
        quote = self.snapshot["quotes"][1]
        accepted = self.snapshot["orders"][1]["accepted_at"]
        for field in ("withdrawn_at", "expires_at"):
            with self.subTest(field=field):
                original = quote[field]
                quote[field] = accepted
                with self.assertRaisesRegex(InvalidSnapshot, "inactive quote"):
                    score(self.snapshot)
                quote[field] = original
        quote["qualified"] = False
        with self.assertRaisesRegex(InvalidSnapshot, "ineligible"):
            score(self.snapshot)

    def test_rejects_wrong_currency_missing_charge_and_impossible_refunds(self):
        order = self.snapshot["orders"][0]
        for key, value, message in (
            ("currency", "JPY", "currencies differ"),
            ("gross_minor", 999, "refunds exceed"),
            ("paid_at", None, "confirmed payment"),
            ("returned_at", "2026-01-05T00:00:00Z", "outside"),
            ("reconciled_at", "2026-01-21T00:00:00Z", "outside"),
            ("gross_minor", True, "integer minor units"),
        ):
            with self.subTest(key=key, value=value):
                original = order[key]
                order[key] = value
                with self.assertRaisesRegex(InvalidSnapshot, message):
                    score(self.snapshot)
                order[key] = original
        order["refunds"][1]["id"] = order["refunds"][0]["id"]
        with self.assertRaisesRegex(InvalidSnapshot, "duplicate"):
            score(self.snapshot)

    def test_rejects_fee_reversal_exceeding_charge_and_cost_for_absent_store(self):
        fee = self.snapshot["orders"][0]["fees"]["platform"]
        fee["reversed_minor"] = fee["gross_minor"] + 1
        with self.assertRaisesRegex(InvalidSnapshot, "fee reversals exceed"):
            score(self.snapshot)
        fee["reversed_minor"] = 0
        self.snapshot["orders"][1]["costs_minor"]["servicing_store"] = 1
        with self.assertRaisesRegex(InvalidSnapshot, "absent servicing store"):
            score(self.snapshot)

    def test_rejects_future_or_unlinked_evidence(self):
        invite = self.snapshot["invitations"][0]
        invite["responded_at"] = "2026-04-11T00:00:00Z"
        with self.assertRaisesRegex(InvalidSnapshot, "outside"):
            score(self.snapshot)
        invite["responded_at"] = None
        with self.assertRaisesRegex(InvalidSnapshot, "requires a merchant response"):
            score(self.snapshot)

    def test_cli_rejects_unknown_fields_and_duplicate_json_keys_without_echoing_data(self):
        for bad in (
            '{"name": "private-token"}',
            '{"dataset":"synthetic","dataset":"private-token"}',
        ):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "test.json"
                path.write_text(bad, encoding="utf-8")
                result = subprocess.run([sys.executable, str(HERE / "scorecard.py"), str(path)],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("private-token", result.stderr)


if __name__ == "__main__":
    unittest.main()
