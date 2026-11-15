"""Controls for the simulation-to-CommerceCore projection.

The hand fixture is independent of the simulation engine. Canonical metric
expectations are replayed by pilot_interop.py against the real Elixir reader;
this file does not implement a second copy of that reader.
"""

from copy import deepcopy
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from experiments.economic_simulation.pilot import (  # noqa: E402
    PilotExportError,
    export_pilot_snapshot,
    idmap,
)


def pilot_fixture() -> tuple[dict, dict]:
    """Six observed requests, one future request, and three accepted orders."""
    specs = [
        ("boundary", 0, 168, None, None),
        ("accepted", 0, 1, None, None),
        ("withdrawn", 0, 4, 20, 8),
        ("immature", 1, 2, None, None),
        ("overdue", 0, 1, None, None),
        ("inactive", 0, 1, None, 1),
        ("future", 169, 170, None, None),
    ]
    scenario = {
        "schema_version": "1.0", "scenario_id": "pilot-contract-control",
        "start_at": "2026-01-01T00:00:00Z", "observed_until_hour": 168,
        "currency": "USD", "businesses": [{"id": "buyer"}, {"id": "seller"}],
        "requests": [], "offers": [], "policy": {"mechanism": "purchase"},
    }
    result = {
        "schema_version": "1.0", "source": "synthetic", "scenario": scenario,
        "provenance": {"fixture": "hand-calculated contract control"},
        "metrics": {
            "quote_rate_7d": {"numerator": 4, "denominator": 5, "rate": 0.8},
            "commitment_rate_7d": {"numerator": 2, "denominator": 5, "rate": 0.4},
            "fulfillment_rate_7d": {"numerator": 0, "denominator": 5, "rate": 0.0},
            "pilot_quote_rate_7d": {"numerator": 3, "denominator": 4, "rate": 0.75},
        },
        "requests": [], "invitations": [], "quotes": [], "orders": [], "events": [],
    }
    for name, qualified, issued, withdrawn, quote_withdrawn in specs:
        scenario["requests"].append({
            "id": name, "buyer_id": "buyer", "category": "flour", "area": "pilot-area",
            "unit": "bag", "quantity": 2, "qualified_at_hour": qualified,
            "due_at_hour": 240, "max_unit_price_minor": 600,
            "withdraw_at_hour": withdrawn, "exchange_offer_id": None,
        })
        scenario["offers"].append({
            "id": "offer-" + name, "seller_id": "seller", "category": "flour",
            "area": "pilot-area", "unit": "bag", "quantity": 2,
            "available_at_hour": 0, "expires_at_hour": 300,
            "unit_price_minor": 500, "delivery_hours": 1,
        })
        result["requests"].append({
            "id": name, "qualified_at_hour": qualified,
            "first_quote_hour": issued if quote_withdrawn != issued else None,
            "first_commitment_hour": None, "fulfilled_at_hour": None,
            "withdrawn_at_hour": withdrawn, "status": "open",
        })
        result["invitations"].append({
            "id": "invitation-" + name, "request_id": name, "offer_id": "offer-" + name,
            "seller_id": "seller", "invited_at_hour": qualified,
            "responded_at_hour": issued, "response": "quote",
        })
        result["quotes"].append({
            "id": "quote-" + name, "request_id": name, "offer_id": "offer-" + name,
            "seller_id": "seller", "issued_at_hour": issued, "expires_at_hour": 250,
            "withdrawn_at_hour": quote_withdrawn, "unit_price_minor": 500, "quantity": 2,
        })
    for name, accepted, promised, delivered, buyer_accepted in [
        ("accepted", 2, 5, 3, 169),
        ("immature", 3, 200, 200, 201),
        ("overdue", 2, 10, None, None),
    ]:
        result["orders"].append({
            "id": "order-" + name, "request_id": name, "quote_id": "quote-" + name,
            "offer_id": "offer-" + name, "seller_id": "seller", "buyer_id": "buyer",
            "quantity": 2, "unit_price_minor": 500, "accepted_at_hour": accepted,
            "promised_at_hour": promised, "delivered_at_hour": delivered,
            "buyer_accepted_at_hour": buyer_accepted, "failed_at_hour": None,
            "cancelled_at_hour": None, "cycle_id": None, "attempt": 1,
        })
        state = next(row for row in result["requests"] if row["id"] == name)
        state["first_commitment_hour"] = accepted
        state["fulfilled_at_hour"] = buyer_accepted if buyer_accepted is not None and buyer_accepted <= 168 else None
        state["status"] = "committed"
    return scenario, result


def canonical_controls() -> list[tuple[str, dict, dict]]:
    """Expected projections to verify using the authoritative Elixir CLI."""
    scenario, result = pilot_fixture()
    base = export_pilot_snapshot(scenario, result)
    controls = [("mature-boundary-and-distinct-metrics", base, {
        "demand.qualified_requests": 6,
        "demand.seven_day_match": {"numerator": 3, "denominator": 4, "incomplete": 1, "withdrawn_early": 1},
        "demand.first_quote_within_seven_days": {"median_seconds": 3600.0, "observed": 3, "unmatched_mature": 1},
        "demand.seven_day_invitation_response": {"numerator": 4, "denominator": 4},
        "demand.requests_with_accepted_order": 3,
        "orders.accepted_orders": 3,
        "orders.realized_orders": 0,
        "orders.on_time_fulfillment": {"numerator": 1, "denominator": 1, "incomplete": 2, "pending_past_promise": 1},
        "economics.by_currency.USD.merchant.complete": 0,
        "economics.by_currency.USD.merchant.unreconciled": 3,
        "economics.by_currency.USD.merchant.unallocated_cost_minor": None,
    })]
    scenario, result = pilot_fixture()
    scenario["observed_until_hour"] = 167
    controls.append(("one-hour-short-is-immature", export_pilot_snapshot(scenario, result), {
        "demand.seven_day_match": {"numerator": 0, "denominator": 0, "incomplete": 5, "withdrawn_early": 1},
        "demand.first_quote_within_seven_days.median_seconds": None,
    }))
    scenario, result = pilot_fixture()
    for row in result["requests"]:
        if row["id"] == "withdrawn":
            row["withdrawn_at_hour"] = 168
    controls.append(("withdrawal-at-day-seven-is-mature", export_pilot_snapshot(scenario, result), {
        "demand.seven_day_match": {"numerator": 4, "denominator": 5, "incomplete": 1, "withdrawn_early": 0},
    }))
    scenario, result = pilot_fixture()
    overdue = next(row for row in result["orders"] if row["request_id"] == "overdue")
    overdue["failed_at_hour"] = 100
    controls.append(("failed-order-enters-final-outcomes", export_pilot_snapshot(scenario, result), {
        "orders.on_time_fulfillment": {"numerator": 1, "denominator": 2, "incomplete": 1, "pending_past_promise": 0},
    }))
    return controls


class PilotProjectionTests(unittest.TestCase):
    def setUp(self):
        self.scenario, self.result = pilot_fixture()

    def test_projection_is_synthetic_deterministic_and_does_not_mutate(self):
        before = deepcopy((self.scenario, self.result))
        first = export_pilot_snapshot(self.scenario, self.result)
        self.assertEqual(first, export_pilot_snapshot(self.scenario, self.result))
        self.assertEqual((self.scenario, self.result), before)
        self.assertEqual(first["dataset"], "synthetic")
        self.assertEqual(first["schema_version"], 1)
        self.assertEqual(set(first), {"schema_version", "dataset", "cohort_started_at", "as_of", "requests",
                                      "invitations", "quotes", "orders", "unallocated_costs"})
        for collection in ("requests", "quotes", "orders"):
            for row in first[collection]:
                self.assertRegex(row["id"], re.compile(r"^[0-9a-f]{32}$"))
        self.assertNotIn("commitment_rate_7d", first)

    def test_id_namespaces_are_unambiguous(self):
        self.assertEqual(idmap("request", "r1"), idmap("request", "r1"))
        self.assertNotEqual(idmap("request", "r1"), idmap("order", "r1"))
        self.assertNotEqual(idmap("a/b", "c"), idmap("a", "b/c"))

    def test_future_events_are_not_exported_but_promises_are_retained(self):
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertEqual(len(snapshot["requests"]), 6)
        self.assertEqual(len(snapshot["quotes"]), 6)
        self.assertEqual(len(snapshot["invitations"]), 6)
        self.assertIn("2026-01-08T00:00:00Z", [row["issued_at"] for row in snapshot["quotes"]])
        pending = [row for row in snapshot["orders"] if row["outcome"] == "pending"]
        self.assertEqual(len(pending), 2)
        self.assertTrue(all(row["outcome_at"] is None for row in pending))
        self.assertIn("2026-01-09T08:00:00Z", [row["promised_by"] for row in pending])

    def test_quoted_total_is_integer_minor_units_and_later_withdrawal_survives(self):
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertTrue(all(row["all_in_minor"] == 1000 for row in snapshot["quotes"]))
        withdrawn = [row for row in snapshot["quotes"] if row["withdrawn_at"] == "2026-01-01T08:00:00Z"]
        self.assertEqual(len(withdrawn), 1)
        self.assertTrue(withdrawn[0]["qualified"])
        self.assertEqual(withdrawn[0]["issued_at"], "2026-01-01T04:00:00Z")

    def test_physical_delivery_does_not_invent_buyer_acceptance_or_payment(self):
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        fulfilled = [row for row in snapshot["orders"] if row["outcome"] == "fulfilled"]
        self.assertEqual(len(fulfilled), 1)
        self.assertEqual(fulfilled[0]["outcome_at"], "2026-01-01T03:00:00Z")
        self.assertEqual(self.result["metrics"]["fulfillment_rate_7d"]["numerator"], 0)
        for order in snapshot["orders"]:
            self.assertIsNone(order["paid_at"])
            self.assertIsNone(order["gross_minor"])
            self.assertIsNone(order["reconciled_at"])
            self.assertIsNone(order["fees"]["platform"])
            self.assertIsNone(order["costs_minor"]["merchant"])
        self.assertTrue(all(row["minor"] is None for row in snapshot["unallocated_costs"]))

    def test_quote_without_commitment_is_preserved(self):
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertEqual(len(snapshot["quotes"]), 6)
        self.assertEqual(len(snapshot["orders"]), 3)
        self.assertEqual(self.result["metrics"]["commitment_rate_7d"]["numerator"], 2)

    def test_repeated_merchant_invitations_collapse_without_invented_responses(self):
        repeated = deepcopy(self.result["invitations"][1])
        repeated.update(id="reminder", invited_at_hour=1, responded_at_hour=4)
        self.result["invitations"].append(repeated)
        self.assertEqual(len(export_pilot_snapshot(self.scenario, self.result)["invitations"]), 6)

    def test_observed_and_barter_exports_are_rejected(self):
        self.result["source"] = "observed"
        with self.assertRaisesRegex(PilotExportError, "synthetic"):
            export_pilot_snapshot(self.scenario, self.result)
        self.result["source"] = "synthetic"
        self.scenario["policy"]["mechanism"] = "barter"
        with self.assertRaisesRegex(PilotExportError, "barter"):
            export_pilot_snapshot(self.scenario, self.result)

    def test_mismatched_scenario_is_rejected(self):
        different = deepcopy(self.scenario)
        different["scenario_id"] = "different"
        with self.assertRaisesRegex(PilotExportError, "exact scenario"):
            export_pilot_snapshot(different, self.result)

    def test_partial_order_and_acceptance_after_quote_expiry_are_rejected(self):
        self.result["orders"][0]["quantity"] = 1
        with self.assertRaisesRegex(PilotExportError, "full-quantity"):
            export_pilot_snapshot(self.scenario, self.result)
        self.result["orders"][0]["quantity"] = 2
        self.result["quotes"][1]["expires_at_hour"] = 2
        with self.assertRaisesRegex(PilotExportError, "inactive quote"):
            export_pilot_snapshot(self.scenario, self.result)

    def test_missing_invitation_and_boolean_hour_are_rejected(self):
        self.result["invitations"].pop(0)
        with self.assertRaisesRegex(PilotExportError, "invitation"):
            export_pilot_snapshot(self.scenario, self.result)
        self.scenario, self.result = pilot_fixture()
        self.scenario["observed_until_hour"] = True
        with self.assertRaisesRegex(PilotExportError, "integers"):
            export_pilot_snapshot(self.scenario, self.result)

    def test_future_response_and_withdrawal_are_not_observed(self):
        self.result["invitations"][0]["responded_at_hour"] = 169
        self.result["quotes"][0]["issued_at_hour"] = 169
        self.result["requests"][0]["withdrawn_at_hour"] = 200
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertEqual(sum(row["responded_at"] is None for row in snapshot["invitations"]), 1)
        self.assertEqual(len(snapshot["quotes"]), 5)
        self.assertEqual(sum(row["withdrawn_at"] is not None for row in snapshot["requests"]), 1)

    def test_quote_terms_must_be_compatible_and_affordable(self):
        self.result["quotes"][0]["unit_price_minor"] = 601
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertEqual(sum(not row["qualified"] for row in snapshot["quotes"]), 1)
        self.scenario["offers"][1]["area"] = "outside-pilot"
        with self.assertRaisesRegex(PilotExportError, "inactive quote"):
            export_pilot_snapshot(self.scenario, self.result)

    def test_same_hour_retry_and_reused_quote_are_rejected(self):
        original = self.result["orders"][2]
        original["failed_at_hour"] = 10
        retry = deepcopy(original)
        retry.update(id="retry", accepted_at_hour=10, promised_at_hour=20, failed_at_hour=None,
                     quote_id="retry-quote", attempt=2)
        quote = deepcopy(self.result["quotes"][4])
        quote.update(id="retry-quote", issued_at_hour=10)
        self.result["quotes"].append(quote)
        self.result["orders"].append(retry)
        with self.assertRaisesRegex(PilotExportError, "same-hour"):
            export_pilot_snapshot(self.scenario, self.result)
        retry["accepted_at_hour"] = 11
        self.assertEqual(len(export_pilot_snapshot(self.scenario, self.result)["orders"]), 4)
        retry["quote_id"] = original["quote_id"]
        with self.assertRaisesRegex(PilotExportError, "unused"):
            export_pilot_snapshot(self.scenario, self.result)


if __name__ == "__main__":
    unittest.main()
