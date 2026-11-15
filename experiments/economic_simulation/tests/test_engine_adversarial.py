"""Adversarial transition checks using small, hand-calculated markets.

Fixtures exercise the public simulator. Expected physical inventory and event
times are calculated independently; no matcher or event-transition internals
are used as the oracle.
"""

from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from experiments.economic_simulation.engine import SimulationLimitError, simulate
from experiments.economic_simulation.matching import MatchingBudgetExceeded
from experiments.economic_simulation.pilot import export_pilot_snapshot
from experiments.economic_simulation.scenario import ScenarioError


def business(identifier, **changes):
    return {"id": identifier, "response_delay_hours": 0, **changes}


def request(identifier="request", buyer="buyer", **changes):
    return {
        "id": identifier, "buyer_id": buyer, "category": "flour", "area": "area",
        "unit": "bag", "quantity": 1, "qualified_at_hour": 0,
        "due_at_hour": 200, "max_unit_price_minor": 100, **changes,
    }


def offer(identifier="offer", seller="seller", **changes):
    return {
        "id": identifier, "seller_id": seller, "category": "flour", "area": "area",
        "unit": "bag", "quantity": 1, "available_at_hour": 0,
        "expires_at_hour": 300, "unit_price_minor": 10, "delivery_hours": 1,
        **changes,
    }


def purchase(**changes):
    return {
        "schema_version": "1.0", "scenario_id": "adversarial-control",
        "start_at": "2026-01-01T00:00:00Z", "observed_until_hour": 168,
        "currency": "USD", "businesses": [business("buyer"), business("seller")],
        "requests": [request()], "offers": [offer()], **changes,
    }


def barter_ring(size=5, **changes):
    return purchase(
        businesses=[business(f"business-{i}") for i in range(size)],
        requests=[request(
            f"request-{i}", f"business-{i}", category=f"good-{(i - 1) % size}",
            exchange_offer_id=f"offer-{i}",
            acceptable_offer_ids=[f"offer-{(i - 1) % size}"],
        ) for i in range(size)],
        offers=[offer(f"offer-{i}", f"business-{i}", category=f"good-{i}")
                for i in range(size)],
        policy={"mechanism": "barter"},
        **changes,
    )


class EngineAdversarialTests(unittest.TestCase):
    def assert_physical_conservation(self, result):
        initial = {row["id"]: row["quantity"] for row in result["scenario"]["offers"]}
        balances = {key: {"reserved": 0, "delivered": 0} for key in initial}
        orders = {row["id"]: row for row in result["orders"]}
        last_hour = -1
        for event in result["events"]:
            self.assertGreaterEqual(event["hour"], last_hour)
            self.assertLessEqual(event["hour"], result["scenario"]["observed_until_hour"])
            last_hour = event["hour"]
            kind, data = event["kind"], event["data"]
            if kind == "committed":
                balances[data["offer_id"]]["reserved"] += data["quantity"]
            elif kind in ("delivered", "failed", "cancelled"):
                order = orders[data["order_id"]]
                balance = balances[order["offer_id"]]
                balance["reserved"] -= order["quantity"]
                if kind == "delivered":
                    balance["delivered"] += order["quantity"]
            for key, balance in balances.items():
                self.assertGreaterEqual(balance["reserved"], 0)
                self.assertGreaterEqual(balance["delivered"], 0)
                self.assertLessEqual(balance["reserved"] + balance["delivered"], initial[key])
        for row in result["inventory"]:
            expected = balances[row["offer_id"]]
            self.assertEqual(row["reserved"], expected["reserved"])
            self.assertEqual(row["delivered"], expected["delivered"])
            self.assertEqual(row["available"], row["initial"] - row["reserved"] - row["delivered"])

    def test_scarce_capacity_can_generate_quotes_but_only_one_commitment(self):
        scenario = purchase(
            requests=[request("a"), request("b")],
            offers=[offer(quantity=1, delivery_hours=10)],
        )
        result = simulate(scenario)
        self.assertEqual(result["metrics"]["quote_rate_7d"]["numerator"], 2)
        self.assertEqual(result["metrics"]["commitment_rate_7d"]["numerator"], 1)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"]["numerator"], 1)
        self.assertEqual(len(result["orders"]), 1)
        self.assert_physical_conservation(result)

    def test_released_capacity_wakes_another_request_without_retrying_failed_request(self):
        scenario = purchase(
            businesses=[business("buyer"), business("seller", fulfillment_probability=0)],
            requests=[request("a"), request("b")],
            policy={"rematch_rounds": 0, "cadence_hours": 0},
        )
        result = simulate(scenario)
        self.assertEqual([row["request_id"] for row in result["orders"]], ["a", "b"])
        self.assertEqual([row["attempt"] for row in result["orders"]], [1, 1])
        self.assertEqual([row["accepted_at_hour"] for row in result["orders"]], [0, 2])
        self.assertEqual(result["inventory"][0]["available"], 1)
        self.assert_physical_conservation(result)

    def test_retry_obtains_fresh_quote_after_failure_and_response_delay(self):
        scenario = purchase(
            businesses=[business("buyer"), business("bad", response_delay_hours=2),
                        business("good", response_delay_hours=2)],
            offers=[offer("bad-offer", "bad", unit_price_minor=1, delivery_hours=10),
                    offer("good-offer", "good", unit_price_minor=2)],
            policy={"rematch_rounds": 1},
            shocks=[{"kind": "business_exit", "business_id": "bad", "at_hour": 4}],
        )
        result = simulate(scenario)
        self.assertEqual(len(result["orders"]), 2)
        first, second = result["orders"]
        self.assertEqual(first["accepted_at_hour"], 2)
        self.assertEqual(first["failed_at_hour"], 4)
        self.assertEqual(second["seller_id"], "good")
        self.assertEqual(second["accepted_at_hour"], 7)
        quote = next(row for row in result["quotes"] if row["id"] == second["quote_id"])
        self.assertEqual(quote["issued_at_hour"], 7)
        self.assertEqual(quote["revision"], 2)
        self.assertEqual(result["requests"][0]["fulfilled_at_hour"], 8)
        self.assertEqual(result["metrics"]["recovered_requests"], 1)
        export_pilot_snapshot(result["scenario"], result)
        self.assert_physical_conservation(result)

    def test_declined_proposal_does_not_erase_a_historical_qualified_quote(self):
        scenario = purchase(businesses=[business("buyer", acceptance_probability=0), business("seller")])
        result = simulate(scenario)
        self.assertEqual(result["metrics"]["quote_rate_7d"]["rate"], 1)
        self.assertEqual(result["metrics"]["commitment_rate_7d"]["rate"], 0)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"]["rate"], 0)
        self.assertIsNone(result["quotes"][0]["withdrawn_at_hour"])
        self.assertEqual(sum(event["kind"] == "proposal_declined" for event in result["events"]), 1)
        snapshot = export_pilot_snapshot(result["scenario"], result)
        self.assertTrue(snapshot["quotes"][0]["qualified"])
        self.assertIsNone(snapshot["quotes"][0]["withdrawn_at"])

    def test_exact_168_hour_maturity_keeps_immature_requests_separate(self):
        scenario = purchase(requests=[request("mature"), request("immature", qualified_at_hour=1)],
                            offers=[offer(quantity=2)])
        result = simulate(scenario)
        self.assertEqual(result["metrics"]["qualified_requests"], 2)
        self.assertEqual(result["metrics"]["mature_requests"], 1)
        self.assertEqual(result["metrics"]["immature_requests"], 1)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"],
                         {"numerator": 1, "denominator": 1, "rate": 1.0})
        scenario["observed_until_hour"] = 167
        earlier = simulate(scenario)
        self.assertEqual(earlier["metrics"]["mature_requests"], 0)
        self.assertIsNone(earlier["metrics"]["quote_rate_7d"]["rate"])

    def test_quote_at_exactly_168_hours_counts_without_inventing_future_delivery(self):
        scenario = purchase(offers=[offer(available_at_hour=168)])
        result = simulate(scenario)
        self.assertEqual(result["requests"][0]["first_quote_hour"], 168)
        self.assertEqual(result["metrics"]["quote_rate_7d"]["rate"], 1)
        self.assertEqual(result["metrics"]["commitment_rate_7d"]["rate"], 1)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"]["rate"], 0)
        self.assertIsNone(result["orders"][0]["delivered_at_hour"])
        self.assertEqual(result["metrics"]["pending_orders"], 1)
        self.assertEqual(result["metrics"]["original_promise_reliability"]["denominator"], 0)
        self.assert_physical_conservation(result)

    def test_zero_delay_failures_preserve_consumed_quotes_and_strictly_later_retry(self):
        scenario = purchase(
            businesses=[business("buyer"), business("seller", fulfillment_probability=0)],
            offers=[offer(delivery_hours=0)], policy={"rematch_rounds": 1},
        )
        result = simulate(scenario)
        self.assertEqual([row["accepted_at_hour"] for row in result["orders"]], [0, 1])
        self.assertEqual([row["failed_at_hour"] for row in result["orders"]], [0, 1])
        self.assertEqual([row["withdrawn_at_hour"] for row in result["quotes"]], [None, None])
        self.assertEqual(len({row["quote_id"] for row in result["orders"]}), 2)
        export_pilot_snapshot(result["scenario"], result)
        self.assert_physical_conservation(result)

    def test_early_withdrawal_is_failure_in_full_cohort_but_excluded_by_pilot_definition(self):
        scenario = purchase(requests=[request(withdraw_at_hour=20)], offers=[])
        result = simulate(scenario)
        self.assertEqual(result["metrics"]["quote_rate_7d"],
                         {"numerator": 0, "denominator": 1, "rate": 0.0})
        self.assertEqual(result["metrics"]["pilot_quote_rate_7d"],
                         {"numerator": 0, "denominator": 0, "rate": None})
        scenario["requests"][0]["withdraw_at_hour"] = 168
        boundary = simulate(scenario)
        self.assertEqual(boundary["metrics"]["pilot_quote_rate_7d"]["denominator"], 1)
        self.assertEqual(boundary["metrics"]["early_withdrawn_mature_requests"], 0)

    def test_later_business_exit_does_not_withdraw_an_already_fulfilled_request(self):
        scenario = purchase(shocks=[{"kind": "business_exit", "business_id": "buyer", "at_hour": 20}])
        result = simulate(scenario)
        self.assertEqual(result["requests"][0]["fulfilled_at_hour"], 1)
        self.assertIsNone(result["requests"][0]["withdrawn_at_hour"])
        self.assertEqual(result["metrics"]["pilot_quote_rate_7d"]["denominator"], 1)

    def test_future_shocks_do_not_change_earlier_decisions(self):
        scenario = purchase(offers=[offer(delivery_hours=60)])
        baseline = simulate(scenario, seed=41)
        scenario["shocks"] = [{"kind": "business_exit", "business_id": "seller", "at_hour": 50}]
        shocked = simulate(scenario, seed=41)
        for result in (baseline, shocked):
            self.assertEqual(result["orders"][0]["accepted_at_hour"], 0)
        self.assertEqual([e for e in baseline["events"] if e["hour"] < 50],
                         [e for e in shocked["events"] if e["hour"] < 50])
        self.assertEqual(shocked["orders"][0]["failed_at_hour"], 50)
        self.assertEqual(baseline["orders"][0]["delivered_at_hour"], 60)

    def test_carrier_outage_delays_delivery_without_rewriting_original_promise(self):
        scenario = purchase(
            requests=[request(due_at_hour=15)], offers=[offer(delivery_hours=10)],
            shocks=[{"kind": "carrier_outage", "area": "area", "starts_at_hour": 5,
                     "ends_at_hour": 20}],
        )
        result = simulate(scenario)
        self.assertEqual(result["orders"][0]["promised_at_hour"], 10)
        self.assertEqual(result["orders"][0]["delivered_at_hour"], 20)
        self.assertEqual(result["metrics"]["original_promise_reliability"]["rate"], 0)
        self.assertEqual(result["metrics"]["original_due_date_fulfillment"]["rate"], 0)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"]["rate"], 1)
        self.assert_physical_conservation(result)

    def test_leg_failure_keeps_seller_available_but_business_exit_removes_future_supply(self):
        scenario = purchase(
            requests=[request("a"), request("b"), request("c", qualified_at_hour=20)],
            offers=[offer(quantity=3, delivery_hours=10)],
            businesses=[business("buyer"), business("seller", fulfillment_probability=0)],
            observed_until_hour=188,
        )
        leg_failures = simulate(scenario)
        self.assertEqual(len(leg_failures["orders"]), 3)
        self.assertEqual(leg_failures["metrics"]["failed_orders"], 3)
        scenario["businesses"][1]["fulfillment_probability"] = 1
        scenario["shocks"] = [{"kind": "business_exit", "business_id": "seller", "at_hour": 5}]
        business_exit = simulate(scenario)
        self.assertEqual(len(business_exit["orders"]), 2)
        self.assertEqual([row["failed_at_hour"] for row in business_exit["orders"]], [5, 5])
        self.assertEqual(next(r for r in business_exit["requests"] if r["id"] == "c")["attempts"], 0)
        self.assert_physical_conservation(leg_failures)
        self.assert_physical_conservation(business_exit)

    def test_five_party_barter_cycle_is_allowed_by_default(self):
        scenario = barter_ring()
        result = simulate(scenario)
        self.assertEqual(len(result["cycles"]), 1)
        self.assertEqual(len(result["cycles"][0]["request_ids"]), 5)
        self.assertEqual(result["metrics"]["fulfilled_cycles"], 1)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"]["rate"], 1)
        self.assert_physical_conservation(result)
        scenario["policy"]["max_cycle_length"] = 4
        bounded = simulate(scenario)
        self.assertEqual(bounded["metrics"]["quote_rate_7d"]["rate"], 1)
        self.assertEqual(bounded["orders"], [])
        self.assertEqual(bounded["metrics"]["commitment_rate_7d"]["rate"], 0)

    def test_partial_barter_failure_preserves_delivered_goods_and_reports_stranding(self):
        scenario = barter_ring(3)
        scenario["businesses"][1]["fulfillment_probability"] = 0
        for row, delay in zip(scenario["offers"], (1, 3, 5)):
            row["delivery_hours"] = delay
        result = simulate(scenario)
        self.assertEqual(result["cycles"][0]["status"], "failed")
        self.assertEqual(result["metrics"]["fulfilled_cycles"], 0)
        self.assertEqual(result["metrics"]["fulfillment_rate_7d"]["numerator"], 1)
        self.assertEqual(result["metrics"]["stranded_outgoing_legs"], 1)
        self.assertEqual(result["metrics"]["stranded_value_at_cost_minor"], 10)
        outgoing = next(row for row in result["orders"] if row["offer_id"] == "offer-0")
        self.assertEqual(outgoing["delivered_at_hour"], 1)
        self.assertIsNone(outgoing["failed_at_hour"])
        self.assertIsNone(outgoing["cancelled_at_hour"])
        inventory = next(row for row in result["inventory"] if row["offer_id"] == "offer-0")
        self.assertEqual(inventory["available"], 0)
        self.assert_physical_conservation(result)

    def test_receipt_delay_preserves_delivered_goods_after_request_withdrawal(self):
        scenario = purchase(
            businesses=[business("buyer", receipt_delay_hours=5), business("seller")],
            requests=[request(withdraw_at_hour=3)],
        )
        result = simulate(scenario)
        order = result["orders"][0]
        self.assertEqual(order["delivered_at_hour"], 1)
        self.assertEqual(order["buyer_accepted_at_hour"], 6)
        self.assertIsNone(order["cancelled_at_hour"])
        self.assertIsNone(order["failed_at_hour"])
        self.assertEqual(result["requests"][0]["withdrawn_at_hour"], 3)
        self.assertEqual(result["requests"][0]["fulfilled_at_hour"], 6)
        self.assert_physical_conservation(result)

    def test_seed_and_input_order_are_deterministic_and_input_is_unchanged(self):
        scenario = barter_ring(5)
        scenario["businesses"][0]["acceptance_probability"] = 0.7
        before = deepcopy(scenario)
        baseline = simulate(scenario, seed=845)
        repeated = simulate(scenario, seed=845)
        self.assertEqual(scenario, before)
        # The team may edit source files concurrently; provenance intentionally
        # fingerprints those changes. Compare the complete economic result.
        baseline.pop("provenance")
        repeated.pop("provenance")
        self.assertEqual(baseline, repeated)
        for field in ("businesses", "requests", "offers"):
            scenario[field].reverse()
        permuted = simulate(scenario, seed=845)
        permuted.pop("provenance")
        self.assertEqual(baseline, permuted)

    def test_limits_refuse_without_certifying_an_incomplete_simulation(self):
        for controls in ({"max_events": 1}, {"max_candidate_pairs": 1}):
            scenario = purchase(requests=[request("a"), request("b")], limits=controls)
            for _ in range(2):
                with self.assertRaises(SimulationLimitError):
                    simulate(scenario)
        scenario = barter_ring(limits={"solver_work_budget": 1})
        with self.assertRaises(MatchingBudgetExceeded):
            simulate(scenario)

    def test_empty_and_no_response_markets_never_invent_a_match(self):
        empty = simulate(purchase(businesses=[], requests=[], offers=[]))
        self.assertEqual(empty["orders"], [])
        self.assertEqual(empty["events"], [])
        self.assertIsNone(empty["metrics"]["quote_rate_7d"]["rate"])
        no_response = simulate(purchase(businesses=[business("buyer"), business("seller", response_probability=0)]))
        self.assertEqual(no_response["metrics"]["no_response_invitations"], 1)
        self.assertEqual(no_response["quotes"], [])
        self.assertEqual(no_response["orders"], [])
        self.assertEqual(no_response["metrics"]["quote_rate_7d"]["rate"], 0)

    def test_invalid_random_seeds_are_rejected(self):
        for seed in (True, False, -1, 2**63, 0.5, "0"):
            with self.subTest(seed=seed):
                with self.assertRaises(ScenarioError):
                    simulate(purchase(), seed=seed)


if __name__ == "__main__":
    unittest.main()
