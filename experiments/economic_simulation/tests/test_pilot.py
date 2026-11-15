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
        "schema_version": "1.0",
        "scenario_id": "pilot-contract-control",
        "start_at": "2026-01-01T00:00:00Z",
        "observed_until_hour": 168,
        "currency": "USD",
        "businesses": [{"id": "buyer"}, {"id": "seller"}],
        "requests": [],
        "offers": [],
        "policy": {"mechanism": "purchase"},
    }
    result = {
        "schema_version": "1.0",
        "source": "synthetic",
        "scenario": scenario,
        "provenance": {"fixture": "hand-calculated contract control"},
        "metrics": {
            "quote_rate_7d": {"numerator": 4, "denominator": 5, "rate": 0.8},
            "commitment_rate_7d": {"numerator": 2, "denominator": 5, "rate": 0.4},
            "fulfillment_rate_7d": {"numerator": 0, "denominator": 5, "rate": 0.0},
            "pilot_quote_rate_7d": {"numerator": 3, "denominator": 4, "rate": 0.75},
        },
        "requests": [],
        "invitations": [],
        "quotes": [],
        "orders": [],
        "events": [],
    }
    for name, qualified, issued, withdrawn, quote_withdrawn in specs:
        scenario["requests"].append(
            {
                "id": name,
                "buyer_id": "buyer",
                "category": "flour",
                "area": "pilot-area",
                "unit": "bag",
                "quantity": 2,
                "qualified_at_hour": qualified,
                "due_at_hour": 240,
                "max_unit_price_minor": 600,
                "withdraw_at_hour": withdrawn,
                "exchange_offer_id": None,
            }
        )
        scenario["offers"].append(
            {
                "id": "offer-" + name,
                "seller_id": "seller",
                "category": "flour",
                "area": "pilot-area",
                "unit": "bag",
                "quantity": 2,
                "available_at_hour": 0,
                "expires_at_hour": 300,
                "unit_price_minor": 500,
                "delivery_hours": 1,
            }
        )
        result["requests"].append(
            {
                "id": name,
                "qualified_at_hour": qualified,
                "first_quote_hour": issued if quote_withdrawn != issued else None,
                "first_commitment_hour": None,
                "fulfilled_at_hour": None,
                "withdrawn_at_hour": withdrawn,
                "status": "open",
            }
        )
        result["invitations"].append(
            {
                "id": "invitation-" + name,
                "request_id": name,
                "offer_id": "offer-" + name,
                "seller_id": "seller",
                "invited_at_hour": qualified,
                "responded_at_hour": issued,
                "response": "quote",
            }
        )
        result["quotes"].append(
            {
                "id": "quote-" + name,
                "request_id": name,
                "offer_id": "offer-" + name,
                "seller_id": "seller",
                "issued_at_hour": issued,
                "expires_at_hour": 250,
                "withdrawn_at_hour": quote_withdrawn,
                "unit_price_minor": 500,
                "quantity": 2,
            }
        )
    for name, accepted, promised, delivered, buyer_accepted in [
        ("accepted", 2, 5, 3, 169),
        ("immature", 3, 200, 200, 201),
        ("overdue", 2, 10, None, None),
    ]:
        result["orders"].append(
            {
                "id": "order-" + name,
                "request_id": name,
                "quote_id": "quote-" + name,
                "offer_id": "offer-" + name,
                "seller_id": "seller",
                "buyer_id": "buyer",
                "quantity": 2,
                "unit_price_minor": 500,
                "accepted_at_hour": accepted,
                "promised_at_hour": promised,
                "delivered_at_hour": delivered,
                "buyer_accepted_at_hour": buyer_accepted,
                "failed_at_hour": None,
                "cancelled_at_hour": None,
                "cycle_id": None,
                "attempt": 1,
            }
        )
        state = next(row for row in result["requests"] if row["id"] == name)
        state["first_commitment_hour"] = accepted
        state["fulfilled_at_hour"] = (
            buyer_accepted
            if buyer_accepted is not None and buyer_accepted <= 168
            else None
        )
        state["status"] = "committed"
    return scenario, result


def canonical_controls() -> list[tuple[str, dict, dict]]:
    """Expected projections to verify using the authoritative Elixir CLI."""
    scenario, result = pilot_fixture()
    base = export_pilot_snapshot(scenario, result)
    controls = [
        (
            "mature-boundary-and-distinct-metrics",
            base,
            {
                "demand.qualified_requests": 6,
                "demand.seven_day_match": {
                    "numerator": 3,
                    "denominator": 4,
                    "incomplete": 1,
                    "withdrawn_early": 1,
                },
                "demand.first_quote_within_seven_days": {
                    "median_seconds": 3600.0,
                    "observed": 3,
                    "unmatched_mature": 1,
                },
                "demand.seven_day_invitation_response": {
                    "numerator": 4,
                    "denominator": 4,
                },
                "demand.requests_with_accepted_order": 3,
                "orders.accepted_orders": 3,
                "orders.realized_orders": 0,
                "orders.on_time_fulfillment": {
                    "numerator": 1,
                    "denominator": 1,
                    "incomplete": 2,
                    "pending_past_promise": 1,
                },
                "economics.by_currency.USD.merchant.complete": 0,
                "economics.by_currency.USD.merchant.unreconciled": 3,
                "economics.by_currency.USD.merchant.unallocated_cost_minor": None,
            },
        )
    ]
    scenario, result = pilot_fixture()
    scenario["observed_until_hour"] = 167
    controls.append(
        (
            "one-hour-short-is-immature",
            export_pilot_snapshot(scenario, result),
            {
                "demand.seven_day_match": {
                    "numerator": 0,
                    "denominator": 0,
                    "incomplete": 5,
                    "withdrawn_early": 1,
                },
                "demand.first_quote_within_seven_days.median_seconds": None,
            },
        )
    )
    scenario, result = pilot_fixture()
    for row in result["requests"]:
        if row["id"] == "withdrawn":
            row["withdrawn_at_hour"] = 168
    controls.append(
        (
            "withdrawal-at-day-seven-is-mature",
            export_pilot_snapshot(scenario, result),
            {
                "demand.seven_day_match": {
                    "numerator": 4,
                    "denominator": 5,
                    "incomplete": 1,
                    "withdrawn_early": 0,
                },
            },
        )
    )
    scenario, result = pilot_fixture()
    overdue = next(row for row in result["orders"] if row["request_id"] == "overdue")
    overdue["failed_at_hour"] = 100
    controls.append(
        (
            "failed-order-enters-final-outcomes",
            export_pilot_snapshot(scenario, result),
            {
                "orders.on_time_fulfillment": {
                    "numerator": 1,
                    "denominator": 2,
                    "incomplete": 1,
                    "pending_past_promise": 0,
                },
            },
        )
    )
    return controls


def _check_paths(document: dict, expected: dict, context: str) -> None:
    """Explicit checks remain active under python -O as well as unittest."""
    for path, value in expected.items():
        actual = document
        for part in path.split("."):
            actual = actual[int(part)] if isinstance(actual, list) else actual[part]
        if actual != value:
            raise ValueError(
                f"{context}: unexpected {path}: {actual!r}, expected {value!r}"
            )


def engine_controls() -> list[tuple[str, dict, dict]]:
    """Actual simulations, with fixed small-case oracles and cohort differentials.

    Generated-cohort counts are compared against both the model's pilot metric
    and physical outcome rows. They are not the only oracle: deterministic
    fixtures below independently specify exact counts and transition times.
    """
    from experiments.economic_simulation.engine import simulate
    from experiments.economic_simulation.generator import generate_market

    def business(identifier, **changes):
        return {"id": identifier, "response_delay_hours": 0, **changes}

    def request(identifier="request", **changes):
        return {
            "id": identifier,
            "buyer_id": "buyer",
            "category": "flour",
            "area": "area",
            "unit": "bag",
            "quantity": 1,
            "qualified_at_hour": 0,
            "due_at_hour": 240,
            "max_unit_price_minor": 100,
            **changes,
        }

    def offer(identifier="offer", seller="seller", **changes):
        return {
            "id": identifier,
            "seller_id": seller,
            "category": "flour",
            "area": "area",
            "unit": "bag",
            "quantity": 1,
            "available_at_hour": 0,
            "expires_at_hour": 300,
            "unit_price_minor": 10,
            "delivery_hours": 1,
            **changes,
        }

    def market(**changes):
        return {
            "schema_version": "1.0",
            "scenario_id": "engine-pilot-control",
            "start_at": "2026-01-01T00:00:00Z",
            "observed_until_hour": 168,
            "currency": "USD",
            "businesses": [business("buyer"), business("seller")],
            "requests": [request()],
            "offers": [offer()],
            **changes,
        }

    controls = []

    def add(name, scenario, expected_simulation=None, expected_canonical=None):
        result = simulate(scenario, seed=0)
        _check_paths(result, expected_simulation or {}, name)
        snapshot = export_pilot_snapshot(result["scenario"], result)
        cutoff = result["scenario"]["observed_until_hour"]
        observed_requests = [
            row for row in result["requests"] if row["qualified_at_hour"] <= cutoff
        ]
        early = [
            row
            for row in observed_requests
            if row["withdrawn_at_hour"] is not None
            and row["withdrawn_at_hour"] <= cutoff
            and row["withdrawn_at_hour"] < row["qualified_at_hour"] + 168
        ]
        orders = [row for row in result["orders"] if row["accepted_at_hour"] <= cutoff]

        def occurred(order, field):
            return order[field] is not None and order[field] <= cutoff

        delivered = [row for row in orders if occurred(row, "delivered_at_hour")]
        final = [
            row
            for row in orders
            if any(
                occurred(row, field)
                for field in (
                    "delivered_at_hour",
                    "failed_at_hour",
                    "cancelled_at_hour",
                )
            )
        ]
        pending = [row for row in orders if row not in final]
        pilot = result["metrics"]["pilot_quote_rate_7d"]
        expected = {
            "dataset": "synthetic",
            "demand.qualified_requests": len(observed_requests),
            "demand.seven_day_match.numerator": pilot["numerator"],
            "demand.seven_day_match.denominator": pilot["denominator"],
            "demand.seven_day_match.withdrawn_early": len(early),
            # Canonical early withdrawals include immature requests too.
            "demand.seven_day_match.incomplete": len(observed_requests)
            - pilot["denominator"]
            - len(early),
            "demand.requests_with_accepted_order": len(
                {row["request_id"] for row in orders}
            ),
            "orders.accepted_orders": len(orders),
            "orders.realized_orders": 0,
            "orders.on_time_fulfillment.numerator": sum(
                row["delivered_at_hour"] <= row["promised_at_hour"] for row in delivered
            ),
            "orders.on_time_fulfillment.denominator": len(final),
            "orders.on_time_fulfillment.incomplete": len(pending),
            # Pending at the original promise is due in both contracts.
            "orders.on_time_fulfillment.pending_past_promise": sum(
                row["promised_at_hour"] <= cutoff for row in pending
            ),
            "orders.cancelled.numerator": sum(
                occurred(row, "cancelled_at_hour") for row in orders
            ),
            "orders.cancelled.denominator": len(final),
            "orders.returns_to_date.denominator": len(delivered),
        }
        expected.update(expected_canonical or {})
        # These structural assertions are also exercised without an Elixir
        # runtime. Metric agreement itself is established only by the CLI run.
        if (
            len(snapshot["requests"]) != len(observed_requests)
            or len(snapshot["orders"]) != len(orders)
            or sum(row["outcome"] == "fulfilled" for row in snapshot["orders"])
            != len(delivered)
            or any(row["paid_at"] is not None for row in snapshot["orders"])
        ):
            raise ValueError(
                f"{name}: projection changed observed physical/payment evidence"
            )
        controls.append((name, snapshot, expected))

    add(
        "engine-generated-100-requests",
        generate_market(),
        {
            "metrics.qualified_requests": 100,
            "metrics.mature_requests": 100,
            "metrics.pilot_quote_rate_7d.denominator": 100,
        },
    )
    multiple = generate_market(
        seed=19, requests=40, areas=["north", "south"], categories=["grain", "tools"]
    )
    if {(row["area"], row["category"]) for row in multiple["requests"]} != {
        ("north", "grain"),
        ("north", "tools"),
        ("south", "grain"),
        ("south", "tools"),
    }:
        raise ValueError("multiple-area fixture does not cover all four scopes")
    add(
        "engine-generated-multiple-area-40",
        multiple,
        {
            "metrics.qualified_requests": 40,
            "metrics.mature_requests": 40,
            "metrics.pilot_quote_rate_7d.denominator": 40,
        },
    )
    add(
        "engine-quote-at-168-hours",
        market(offers=[offer(available_at_hour=168)]),
        {
            "requests.0.first_quote_hour": 168,
            "metrics.quote_rate_7d.numerator": 1,
            "metrics.commitment_rate_7d.numerator": 1,
            "metrics.fulfillment_rate_7d.numerator": 0,
            "orders.0.promised_at_hour": 169,
            "orders.0.delivered_at_hour": None,
        },
        {
            "demand.seven_day_match.numerator": 1,
            "demand.seven_day_match.denominator": 1,
            "demand.first_quote_within_seven_days.median_seconds": 604800.0,
            "orders.on_time_fulfillment": {
                "numerator": 0,
                "denominator": 0,
                "incomplete": 1,
                "pending_past_promise": 0,
            },
        },
    )
    add(
        "engine-mature-and-immature",
        market(
            requests=[request("a-mature"), request("b-immature", qualified_at_hour=1)],
            offers=[offer(quantity=2)],
        ),
        {
            "metrics.mature_requests": 1,
            "metrics.immature_requests": 1,
            "metrics.fulfillment_rate_7d.numerator": 1,
            "metrics.fulfillment_rate_7d.denominator": 1,
            "orders.0.delivered_at_hour": 1,
            "orders.1.delivered_at_hour": 2,
        },
        {
            "demand.seven_day_match": {
                "numerator": 1,
                "denominator": 1,
                "incomplete": 1,
                "withdrawn_early": 0,
            },
            "orders.on_time_fulfillment": {
                "numerator": 2,
                "denominator": 2,
                "incomplete": 0,
                "pending_past_promise": 0,
            },
        },
    )
    add(
        "engine-mature-and-immature-early-withdrawals",
        market(
            requests=[
                request("a-withdrawn", withdraw_at_hour=20),
                request("b-immature", qualified_at_hour=1, withdraw_at_hour=10),
                request("c-open"),
            ],
            offers=[],
        ),
        {
            "metrics.quote_rate_7d.numerator": 0,
            "metrics.quote_rate_7d.denominator": 2,
            "metrics.pilot_quote_rate_7d.denominator": 1,
            "metrics.early_withdrawn_mature_requests": 1,
        },
        {
            "demand.seven_day_match": {
                "numerator": 0,
                "denominator": 1,
                "incomplete": 0,
                "withdrawn_early": 2,
            }
        },
    )
    add(
        "engine-buyer-declines-actionable-quote",
        market(
            businesses=[business("buyer", acceptance_probability=0), business("seller")]
        ),
        {
            "metrics.quote_rate_7d.numerator": 1,
            "metrics.commitment_rate_7d.numerator": 0,
            "metrics.fulfillment_rate_7d.numerator": 0,
            "quotes.0.withdrawn_at_hour": None,
            "metrics.accepted_orders": 0,
        },
        {
            "demand.seven_day_match.numerator": 1,
            "demand.requests_with_accepted_order": 0,
            "orders.accepted_orders": 0,
        },
    )
    add(
        "engine-failure-rematch-fresh-quote",
        market(
            businesses=[
                business("buyer"),
                business("bad", response_delay_hours=2),
                business("good", response_delay_hours=2),
            ],
            offers=[
                offer("bad-offer", "bad", unit_price_minor=1, delivery_hours=10),
                offer("good-offer", "good", unit_price_minor=2),
            ],
            policy={"rematch_rounds": 1},
            shocks=[{"kind": "business_exit", "business_id": "bad", "at_hour": 4}],
        ),
        {
            "metrics.accepted_orders": 2,
            "metrics.failed_orders": 1,
            "metrics.recovered_requests": 1,
            "orders.0.accepted_at_hour": 2,
            "orders.0.failed_at_hour": 4,
            "orders.1.accepted_at_hour": 7,
            "orders.1.delivered_at_hour": 8,
            "quotes.2.issued_at_hour": 7,
            "quotes.2.revision": 2,
        },
        {
            "demand.requests_with_accepted_order": 1,
            "orders.accepted_orders": 2,
            "orders.on_time_fulfillment": {
                "numerator": 1,
                "denominator": 2,
                "incomplete": 0,
                "pending_past_promise": 0,
            },
        },
    )
    add(
        "engine-supplier-exit-prevents-later-supply",
        market(
            requests=[
                request("a-in-flight"),
                request("b-after-exit", qualified_at_hour=20),
            ],
            offers=[offer(quantity=2, delivery_hours=10)],
            observed_until_hour=188,
            shocks=[{"kind": "business_exit", "business_id": "seller", "at_hour": 5}],
        ),
        {
            "metrics.accepted_orders": 1,
            "metrics.failed_orders": 1,
            "metrics.quote_rate_7d.numerator": 1,
            "metrics.quote_rate_7d.denominator": 2,
            "orders.0.failed_at_hour": 5,
            "requests.1.first_quote_hour": None,
        },
        {
            "demand.seven_day_match.numerator": 1,
            "demand.seven_day_match.denominator": 2,
            "orders.on_time_fulfillment": {
                "numerator": 0,
                "denominator": 1,
                "incomplete": 0,
                "pending_past_promise": 0,
            },
        },
    )
    add(
        "engine-delivery-before-buyer-receipt",
        market(
            businesses=[business("buyer", receipt_delay_hours=168), business("seller")]
        ),
        {
            "orders.0.delivered_at_hour": 1,
            "orders.0.buyer_accepted_at_hour": None,
            "metrics.fulfillment_rate_7d.numerator": 0,
            "metrics.delivered_awaiting_buyer_acceptance": 1,
        },
        {
            "orders.on_time_fulfillment": {
                "numerator": 1,
                "denominator": 1,
                "incomplete": 0,
                "pending_past_promise": 0,
            }
        },
    )
    add(
        "engine-pending-at-original-promise-cutoff",
        market(
            offers=[offer(delivery_hours=168)],
            shocks=[
                {
                    "kind": "carrier_outage",
                    "area": "area",
                    "starts_at_hour": 167,
                    "ends_at_hour": 170,
                }
            ],
        ),
        {
            "orders.0.promised_at_hour": 168,
            "orders.0.delivered_at_hour": None,
            "metrics.pending_orders": 1,
            "metrics.overdue_pending_orders": 1,
        },
        {
            "orders.on_time_fulfillment": {
                "numerator": 0,
                "denominator": 0,
                "incomplete": 1,
                "pending_past_promise": 1,
            }
        },
    )
    add(
        "engine-late-physical-delivery",
        market(
            requests=[request(due_at_hour=15)],
            offers=[offer(delivery_hours=10)],
            shocks=[
                {
                    "kind": "carrier_outage",
                    "area": "area",
                    "starts_at_hour": 5,
                    "ends_at_hour": 20,
                }
            ],
        ),
        {
            "orders.0.promised_at_hour": 10,
            "orders.0.delivered_at_hour": 20,
            "metrics.fulfillment_rate_7d.numerator": 1,
            "metrics.original_due_date_fulfillment.numerator": 0,
        },
        {
            "orders.on_time_fulfillment": {
                "numerator": 0,
                "denominator": 1,
                "incomplete": 0,
                "pending_past_promise": 0,
            },
            "orders.returns_to_date.denominator": 1,
        },
    )
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
        self.assertEqual(
            set(first),
            {
                "schema_version",
                "dataset",
                "cohort_started_at",
                "as_of",
                "requests",
                "invitations",
                "quotes",
                "orders",
                "unallocated_costs",
            },
        )
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
        self.assertIn(
            "2026-01-08T00:00:00Z", [row["issued_at"] for row in snapshot["quotes"]]
        )
        pending = [row for row in snapshot["orders"] if row["outcome"] == "pending"]
        self.assertEqual(len(pending), 2)
        self.assertTrue(all(row["outcome_at"] is None for row in pending))
        self.assertIn("2026-01-09T08:00:00Z", [row["promised_by"] for row in pending])

    def test_quoted_total_is_integer_minor_units_and_later_withdrawal_survives(self):
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertTrue(all(row["all_in_minor"] == 1000 for row in snapshot["quotes"]))
        withdrawn = [
            row
            for row in snapshot["quotes"]
            if row["withdrawn_at"] == "2026-01-01T08:00:00Z"
        ]
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
        self.assertTrue(
            all(row["minor"] is None for row in snapshot["unallocated_costs"])
        )

    def test_quote_without_commitment_is_preserved(self):
        snapshot = export_pilot_snapshot(self.scenario, self.result)
        self.assertEqual(len(snapshot["quotes"]), 6)
        self.assertEqual(len(snapshot["orders"]), 3)
        self.assertEqual(self.result["metrics"]["commitment_rate_7d"]["numerator"], 2)

    def test_repeated_merchant_invitations_collapse_without_invented_responses(self):
        repeated = deepcopy(self.result["invitations"][1])
        repeated.update(id="reminder", invited_at_hour=1, responded_at_hour=4)
        self.result["invitations"].append(repeated)
        self.assertEqual(
            len(export_pilot_snapshot(self.scenario, self.result)["invitations"]), 6
        )

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
        self.assertEqual(
            sum(row["responded_at"] is None for row in snapshot["invitations"]), 1
        )
        self.assertEqual(len(snapshot["quotes"]), 5)
        self.assertEqual(
            sum(row["withdrawn_at"] is not None for row in snapshot["requests"]), 1
        )

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
        retry.update(
            id="retry",
            accepted_at_hour=10,
            promised_at_hour=20,
            failed_at_hour=None,
            quote_id="retry-quote",
            attempt=2,
        )
        quote = deepcopy(self.result["quotes"][4])
        quote.update(id="retry-quote", issued_at_hour=10)
        self.result["quotes"].append(quote)
        self.result["orders"].append(retry)
        with self.assertRaisesRegex(PilotExportError, "same-hour"):
            export_pilot_snapshot(self.scenario, self.result)
        retry["accepted_at_hour"] = 11
        self.assertEqual(
            len(export_pilot_snapshot(self.scenario, self.result)["orders"]), 4
        )
        retry["quote_id"] = original["quote_id"]
        with self.assertRaisesRegex(PilotExportError, "unused"):
            export_pilot_snapshot(self.scenario, self.result)

    def test_actual_engine_controls_obey_hand_calculated_transition_expectations(self):
        controls = engine_controls()
        self.assertEqual(len(controls), 11)
        self.assertEqual(len({name for name, _, _ in controls}), len(controls))
        self.assertTrue(
            all(snapshot["dataset"] == "synthetic" for _, snapshot, _ in controls)
        )


if __name__ == "__main__":
    unittest.main()
