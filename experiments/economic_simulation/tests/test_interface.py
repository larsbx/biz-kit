"""Public JSON/CLI/replication controls independent of transition internals."""

from copy import deepcopy
from pathlib import Path
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from experiments.economic_simulation.cli import main
from experiments.economic_simulation.comparison import compare
from experiments.economic_simulation.engine import simulate
from experiments.economic_simulation.generator import generate_market, barter_ring
from experiments.economic_simulation.scenario import (
    ScenarioError,
    load_json,
    validate_scenario,
)
from experiments.economic_simulation.schemas.generate import contracts

PACKAGE = ROOT / "experiments/economic_simulation"


class InterfaceTests(unittest.TestCase):
    def test_identical_policies_have_zero_paired_difference(self):
        scenario = generate_market(
            requests=8, suppliers=2, feasible_suppliers=1, intake_hours=24
        )
        before = deepcopy(scenario)
        result = compare(
            scenario, {"a": {"cadence_hours": 0}, "b": {"cadence_hours": 0}}, [1, 2, 3]
        )
        self.assertEqual(scenario, before)
        for metric, summary in result["summaries"]["b"].items():
            self.assertEqual(
                summary["paired_difference_from_baseline"]["mean"], 0, metric
            )
            self.assertEqual(
                summary["paired_difference_from_baseline"]["replicates"], 3
            )
        self.assertEqual(len(result["runs"]), 6)

    def test_batching_can_miss_a_short_original_deadline(self):
        scenario = generate_market(
            requests=1, suppliers=1, feasible_suppliers=1, intake_hours=0
        )
        for business in scenario["businesses"]:
            business.update(
                response_probability=1,
                fulfillment_probability=1,
                response_delay_hours=1,
            )
        scenario["offers"][0]["delivery_hours"] = 1
        scenario["requests"][0]["due_at_hour"] = 10
        result = compare(
            scenario,
            {"immediate": {"cadence_hours": 0}, "daily": {"cadence_hours": 24}},
            [0, 1],
        )
        self.assertEqual(
            result["summaries"]["immediate"]["fulfillment_rate_7d"]["rate"]["mean"], 1
        )
        self.assertEqual(
            result["summaries"]["daily"]["fulfillment_rate_7d"]["rate"]["mean"], 0
        )
        self.assertEqual(
            result["summaries"]["daily"]["fulfillment_rate_7d"][
                "paired_difference_from_baseline"
            ]["mean"],
            -1,
        )

    def test_generation_is_deterministic_and_scope_lots_are_distinct(self):
        kwargs = dict(
            seed=12,
            requests=40,
            suppliers=5,
            feasible_suppliers=2,
            areas=["north", "south"],
            categories=["parts", "repairs"],
            intake_hours=48,
        )
        a = generate_market(**kwargs)
        self.assertEqual(a, generate_market(**kwargs))
        self.assertEqual(len(a["offers"]), 20)
        self.assertEqual(len({o["id"] for o in a["offers"]}), 20)
        offers = {o["id"]: o for o in a["offers"]}
        for request in a["requests"]:
            self.assertEqual(len(request["acceptable_offer_ids"]), 2)
            for identifier in request["acceptable_offer_ids"]:
                self.assertEqual(
                    (offers[identifier]["area"], offers[identifier]["category"]),
                    (request["area"], request["category"]),
                )

    def test_scope_names_cannot_collide_in_generated_lot_identifiers(self):
        scenario = generate_market(
            requests=5,
            suppliers=1,
            feasible_suppliers=1,
            areas=["a-b", "a"],
            categories=["c", "b-c"],
        )
        self.assertEqual(len({o["id"] for o in scenario["offers"]}), 4)
        scenario = generate_market(
            requests=1,
            suppliers=1,
            feasible_suppliers=1,
            areas=["a" * 128],
            categories=["c" * 128],
        )
        self.assertLessEqual(len(scenario["offers"][0]["id"]), 128)

    def test_cli_failure_has_no_success_output(self):
        with tempfile.TemporaryDirectory() as directory:
            bad = Path(directory) / "bad.json"
            bad.write_text('{"schema_version":"2"}')
            output, errors = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                code = main(["run", str(bad)])
            self.assertEqual(code, 2)
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(json.loads(errors.getvalue())["status"], "error")

    def test_cli_roundtrip_emits_stable_result_and_pilot_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            snapshot = Path(directory) / "snapshot.json"
            args = [
                "run",
                str(PACKAGE / "examples/demand_first.json"),
                "--seed",
                "4",
                "--output",
                str(output),
            ]
            self.assertEqual(main(args), 0)
            first = output.read_bytes()
            self.assertEqual(main(args), 0)
            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(main(["pilot", str(output), "--output", str(snapshot)]), 0)
            self.assertEqual(load_json(snapshot)["dataset"], "synthetic")
            self.assertEqual(len(load_json(snapshot)["requests"]), 100)

    def test_nonobject_pilot_input_returns_a_json_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            for payload in ("null", "[]"):
                path.write_text(payload)
                output, errors = io.StringIO(), io.StringIO()
                with (
                    contextlib.redirect_stdout(output),
                    contextlib.redirect_stderr(errors),
                ):
                    code = main(["pilot", str(path)])
                self.assertEqual(code, 2)
                self.assertEqual(output.getvalue(), "")
                self.assertEqual(
                    json.loads(errors.getvalue())["error_type"], "ScenarioError"
                )

    def test_parser_rejects_duplicate_keys_nonfinite_and_unknown_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            for payload in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}'):
                path.write_text(payload)
                with self.assertRaises(ScenarioError):
                    load_json(path)
        value = generate_market(requests=1, suppliers=1, feasible_suppliers=1)
        value["offers"][0]["quantity"] = True
        with self.assertRaises(ScenarioError):
            validate_scenario(value)
        value["offers"][0]["quantity"] = 1
        value["offers"][0]["hidden_capacity"] = 100
        with self.assertRaises(ScenarioError):
            validate_scenario(value)

    def test_published_schemas_are_generated_from_same_contract(self):
        for name, value in contracts().items():
            self.assertEqual(
                load_json(PACKAGE / "schemas" / (name + ".schema.json")), value
            )

    @unittest.skipUnless(
        importlib.util.find_spec("jsonschema"),
        "install locked development group for JSON Schema validation",
    )
    def test_all_example_inputs_and_real_results_validate(self):
        import jsonschema

        schemas = contracts()
        for schema in schemas.values():
            jsonschema.Draft202012Validator.check_schema(schema)
        for name in ("demand_first", "multi_area", "barter_fragility"):
            scenario = load_json(PACKAGE / "examples" / (name + ".json"))
            jsonschema.validate(scenario, schemas["scenario"])
            result = simulate(scenario, seed=7)
            jsonschema.validate(result, schemas["result"])
        invalid = deepcopy(result)
        invalid["source"] = "observed"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(invalid, schemas["result"])
        invalid = deepcopy(result)
        invalid["orders"][0]["quantity"] = -1
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(invalid, schemas["result"])


if __name__ == "__main__":
    unittest.main()
