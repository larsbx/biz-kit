"""Check that errors and vacuous negative-control runs cannot become a pass."""
from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

from verify import fresh_python_environment, run_stage


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
