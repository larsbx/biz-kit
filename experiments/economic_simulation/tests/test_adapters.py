"""Behavioral checks for optional, real third-party adapters.

The dependency-free job may skip unavailable runtimes. The research job must
verify exact installed versions before running this suite, so absence is not a
successful integration check.
"""

import importlib.metadata
import importlib.util
import json
import random
import unittest
from unittest.mock import patch

try:
    from experiments.economic_simulation.adapters import (
        AdapterDependencyError,
        run_mesa_demo,
        run_negotiation,
    )
except ModuleNotFoundError as error:
    if error.name != "experiments":
        raise
    from adapters import AdapterDependencyError, run_mesa_demo, run_negotiation


HAS_MESA = importlib.util.find_spec("mesa") is not None
HAS_NEGMAS = importlib.util.find_spec("negmas") is not None


class AdapterValidationTests(unittest.TestCase):
    def test_malformed_inputs_rejected_before_loading_optional_runtime(self):
        cases = [
            (run_mesa_demo, {"seed": True}),
            (run_mesa_demo, {"steps": 0}),
            (run_mesa_demo, {"agents": -1}),
            (run_mesa_demo, {"agents": 1001}),
            (run_mesa_demo, {"response_probability": float("nan")}),
            (run_mesa_demo, {"withdrawal_probability": 1.1}),
            (run_negotiation, {"seed": -1}),
            (run_negotiation, {"buyer_limit": 1.5}),
            (run_negotiation, {"seller_floor": -1}),
            (run_negotiation, {"max_rounds": 0}),
            (run_negotiation, {"max_rounds": True}),
            (run_negotiation, {"max_rounds": 1001}),
        ]
        with patch(
            "importlib.metadata.version", side_effect=AssertionError("runtime loaded")
        ):
            for function, parameters in cases:
                with self.subTest(function=function.__name__, parameters=parameters):
                    with self.assertRaises(ValueError):
                        function(**parameters)

    def test_missing_runtime_has_actionable_install_message(self):
        with patch(
            "importlib.metadata.version",
            side_effect=importlib.metadata.PackageNotFoundError,
        ):
            for function, extra in (
                (run_mesa_demo, "mesa"),
                (run_negotiation, "negmas"),
            ):
                with self.subTest(extra=extra):
                    with self.assertRaisesRegex(
                        AdapterDependencyError, f"--extra {extra}"
                    ):
                        function()

    def test_unreviewed_runtime_version_rejected(self):
        with patch("importlib.metadata.version", return_value="999.0.0"):
            for function in (run_mesa_demo, run_negotiation):
                with self.assertRaisesRegex(AdapterDependencyError, "999.0.0"):
                    function()


@unittest.skipUnless(
    HAS_MESA, "Install the frozen mesa or research extra for real Mesa checks"
)
class MesaAdapterTests(unittest.TestCase):
    def test_seeded_runs_are_identical_and_json_serializable(self):
        first = run_mesa_demo(seed=42)
        self.assertEqual(first, run_mesa_demo(seed=42))
        self.assertEqual(first, json.loads(json.dumps(first, allow_nan=False)))
        self.assertEqual(first["framework"]["version"], "3.5.2")
        self.assertEqual(first["evidence_boundary"]["fulfillment"], "not_modeled")
        self.assertFalse(first["evidence_boundary"]["response_is_qualified_quote"])

    def test_all_response_and_all_withdrawal_boundaries(self):
        responses = run_mesa_demo(
            steps=3, agents=4, response_probability=1, withdrawal_probability=0
        )
        self.assertEqual(
            responses["summary"],
            {"responses": 12, "withdrawals": 0, "active_at_end": 4},
        )
        withdrawals = run_mesa_demo(
            steps=3, agents=4, response_probability=1, withdrawal_probability=1
        )
        self.assertEqual(
            withdrawals["summary"],
            {"responses": 0, "withdrawals": 4, "active_at_end": 0},
        )
        self.assertEqual(
            [row["eligible_at_start"] for row in withdrawals["daily"]], [4, 0, 0]
        )

    def test_daily_participation_conservation(self):
        result = run_mesa_demo(
            seed=19, steps=20, agents=30, withdrawal_probability=0.15
        )
        active = 30
        for day in result["daily"]:
            self.assertEqual(day["eligible_at_start"], active)
            self.assertEqual(
                day["responses"] + day["no_response"] + day["withdrawals"], active
            )
            active -= day["withdrawals"]
            self.assertEqual(day["active_at_end"], active)
        self.assertEqual(result["summary"]["active_at_end"], active)

    def test_empty_market_and_no_global_random_side_effects(self):
        run_mesa_demo(agents=0)
        before = random.getstate()
        result = run_mesa_demo(seed=1, agents=0)
        self.assertEqual(random.getstate(), before)
        self.assertEqual(result["events"], [])
        self.assertEqual(result["summary"]["responses"], 0)


@unittest.skipUnless(
    HAS_NEGMAS, "Install the frozen negmas or research extra for real NegMAS checks"
)
class NegmasAdapterTests(unittest.TestCase):
    def test_seeded_runs_are_identical_and_json_serializable(self):
        first = run_negotiation(seed=42)
        self.assertEqual(first, run_negotiation(seed=42))
        self.assertEqual(first, json.loads(json.dumps(first, allow_nan=False)))
        self.assertEqual(first["framework"]["version"], "0.17.0")
        self.assertEqual(first["framework"]["license"], "AGPL-3.0-or-later")
        self.assertEqual(first["evidence_boundary"]["fulfillment"], "not_modeled")

    def test_agreements_respect_both_reservations_and_round_bound(self):
        for seed in (0, 1, 42, 2**63 - 1):
            for buyer, seller in ((120, 80), (80, 80), (0, 0), (10**9, 10**9)):
                with self.subTest(seed=seed, buyer=buyer, seller=seller):
                    result = run_negotiation(seed, buyer, seller, max_rounds=7)
                    self.assertEqual(result["status"], "agreement")
                    self.assertGreaterEqual(result["agreement"]["price"], seller)
                    self.assertLessEqual(result["agreement"]["price"], buyer)
                    self.assertLessEqual(result["rounds_executed"], 7)

    def test_nonoverlapping_reservations_terminate_without_agreement(self):
        for rounds in (1, 2, 20):
            result = run_negotiation(
                seed=7, buyer_limit=79, seller_floor=80, max_rounds=rounds
            )
            self.assertIsNone(result["agreement"])
            self.assertEqual(result["status"], "no_agreement")
            self.assertEqual(result["rounds_executed"], rounds)
            self.assertEqual(
                result["termination_reason"], "incompatible_reservation_prices"
            )

    def test_single_round_and_independence_from_unrelated_random_draws(self):
        before = random.getstate()
        try:
            first = run_negotiation(seed=11)
            for _ in range(100):
                random.random()
            self.assertEqual(first, run_negotiation(seed=11))
            result = run_negotiation(seed=11, max_rounds=1)
        finally:
            random.setstate(before)
        self.assertEqual(result["rounds_executed"], 1)
        self.assertEqual(result["agreement"], {"price": 120})


if __name__ == "__main__":
    unittest.main()
