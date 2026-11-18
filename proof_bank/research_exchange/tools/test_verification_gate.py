"""Check that errors and vacuous negative-control runs cannot become a pass."""
from __future__ import annotations

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

from verify import fresh_python_environment, run_stage, validate_plan


class VerificationGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "evidence"
        self.output.mkdir()

    def stage(self, code: str, **options):
        definition = {"id": "case", "command": [sys.executable, "-c", code],
                      "evidence_class": "test", "timeout_seconds": 5, **options}
        with contextlib.redirect_stdout(io.StringIO()):
            return run_stage(definition, self.root, self.output, {}, dict(os.environ))

    def approved_plan(self):
        path = Path(__file__).resolve().parents[1] / "verification.plan.json"
        return json.loads(path.read_text())

    def test_actual_plan_requires_all_twelve_acceptance_stages(self):
        plan = self.approved_plan()
        names = validate_plan(plan)
        self.assertEqual(names, [stage["id"] for stage in plan["stages"]])
        self.assertEqual(len(names), 12)
        self.assertEqual(names[-2:], ["adapter_model_checks", "adapter_acceptance"])

    def test_partial_or_reordered_plan_cannot_pass(self):
        plan = self.approved_plan()
        cases = {}
        for missing in ("lean_independent_replay", "adapter_model_checks", "adapter_acceptance"):
            bad = copy.deepcopy(plan)
            bad["stages"] = [stage for stage in bad["stages"] if stage["id"] != missing]
            cases[f"missing {missing}"] = bad
        bad = copy.deepcopy(plan)
        bad["stages"][-2], bad["stages"][-1] = bad["stages"][-1], bad["stages"][-2]
        cases["reordered acceptance dependencies"] = bad
        bad = copy.deepcopy(plan)
        bad["stages"][-1] = copy.deepcopy(bad["stages"][-2])
        cases["duplicated model stage replaces acceptance"] = bad
        bad = copy.deepcopy(plan)
        extra = copy.deepcopy(bad["stages"][-1])
        extra["id"] = "unreviewed_extra_stage"
        bad["stages"].append(extra)
        cases["extra stage outside approved plan"] = bad
        for name, bad in cases.items():
            with self.subTest(case=name), self.assertRaises(ValueError):
                validate_plan(bad)

    def test_top_level_gate_cannot_accept_failure_exit_codes(self):
        # Negative-control runners must return success only after establishing
        # their expected rejection; a failed runner is never itself evidence.
        for stage_id in ("lean_negative_controls", "adapter_model_checks", "adapter_acceptance"):
            for codes in ([1], [-9], [0, 1], [0, -9], [], [False], [0.0], 0):
                with self.subTest(stage=stage_id, exit_codes=codes):
                    bad = self.approved_plan()
                    stage = next(stage for stage in bad["stages"] if stage["id"] == stage_id)
                    stage["expected_exit_codes"] = codes
                    with self.assertRaises(ValueError):
                        validate_plan(bad)

    def test_completion_evidence_and_bounded_timeout_are_mandatory(self):
        cases = []
        for field, values in (
            ("required_patterns", (None, [], [""], "COMPLETE", [None])),
            ("timeout_seconds", (None, 0, -1, True, 1.5, "60")),
        ):
            absent = self.approved_plan()
            absent["stages"][-1].pop(field)
            cases.append((f"absent {field}", absent))
            for value in values:
                bad = self.approved_plan()
                bad["stages"][-1][field] = value
                cases.append((f"invalid {field}: {value!r}", bad))
        for name, bad in cases:
            with self.subTest(case=name), self.assertRaises(ValueError):
                validate_plan(bad)

    def test_nonzero_exit_cannot_pass(self):
        self.assertEqual(self.stage("raise SystemExit(1)")["status"], "failed")

    def test_missing_success_marker_cannot_pass(self):
        result = self.stage("print('starting')", required_patterns=["COMPLETE"])
        self.assertEqual(result["status"], "failed")

    def test_expected_rejection_requires_the_right_reason(self):
        result = self.stage("print('unknown option'); raise SystemExit(1)",
                            expected_exit_codes=[1], required_patterns=["counterexample"])
        self.assertEqual(result["status"], "failed")

    def test_explicit_counterexample_can_pass_a_negative_control(self):
        result = self.stage("print('counterexample reproduced'); raise SystemExit(1)",
                            expected_exit_codes=[1], required_patterns=["counterexample reproduced"])
        self.assertEqual(result["status"], "passed")

    def test_forbidden_evidence_cannot_pass(self):
        result = self.stage("print('COMPLETE with sorryAx')", required_patterns=["COMPLETE"],
                            forbidden_patterns=["sorryAx"])
        self.assertEqual(result["status"], "failed")

    def test_timeout_cannot_pass_even_when_exit_is_expected(self):
        result = self.stage("import time; time.sleep(10)", timeout_seconds=0.05,
                            expected_exit_codes=[-9])
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["status"], "failed")

    def test_same_size_same_timestamp_stale_bytecode_is_ignored(self):
        module = self.root / "cache_probe.py"
        module.write_text("VALUE = 'old'\n")
        before = module.stat()
        env = dict(os.environ)
        env.pop("PYTHONPYCACHEPREFIX", None)
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        env["PYTHONPATH"] = str(self.root)
        command = [sys.executable, "-c", "import cache_probe; print(cache_probe.VALUE)"]

        def observed(environment):
            return subprocess.check_output(command, cwd=self.root, env=environment, text=True).strip()

        self.assertEqual(observed(env), "old")
        module.write_text("VALUE = 'new'\n")
        os.utime(module, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(observed(env), "old", "fixture must reproduce the stale-bytecode condition")
        fresh = fresh_python_environment(env, self.output / "fresh-python-cache")
        self.assertEqual(observed(fresh), "new")


if __name__ == "__main__":
    unittest.main(verbosity=2)
