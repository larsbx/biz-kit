"""Refuse missing prerequisites, omitted source cases and green-but-skipped runs."""
import importlib.util
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("bridge_source_acceptance",
                                            Path(__file__).with_name("run_source_acceptance.py"))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class SourceGateTests(unittest.TestCase):
    # This independent inventory prevents deletion of a case from the runner
    # from weakening the gate and its controls in the same change.
    expected = ["test_materialization", "test_prohibited_axiom_report", "test_process_bounds",
                "test_dependency_fingerprint", "test_guarded_replay_and_recovery",
                "test_mcp_source_roundtrip_binds_real_replay", "test_mcp_source_binding_and_profile_refusals"]

    def result(self):
        return SimpleNamespace(executed_cases=list(self.expected), testsRun=len(self.expected),
                               skipped=[], expectedFailures=[], unexpectedSuccesses=[], wasSuccessful=lambda: True)

    def test_every_reviewed_source_case_is_required(self):
        acceptance.validate_inventory(self.expected)
        for index in range(len(self.expected)):
            with self.subTest(omitted=self.expected[index]), self.assertRaises(ValueError):
                acceptance.validate_inventory(self.expected[:index] + self.expected[index + 1:])
        for names in (self.expected + self.expected[:1], self.expected + ["unregistered_case"]):
            with self.assertRaises(ValueError):
                acceptance.validate_inventory(names)

    def test_skipped_unexecuted_and_failed_cases_cannot_pass(self):
        acceptance.validate_result(self.expected, self.result())
        for changes in ({"skipped": [("real_acceptance", "no Lean")]},
                        {"executed_cases": self.expected[:-1]}, {"testsRun": 0},
                        {"expectedFailures": [("real_acceptance", "known failure")]},
                        {"unexpectedSuccesses": ["real_acceptance"]},
                        {"wasSuccessful": lambda: False}):
            result = self.result()
            result.__dict__.update(changes)
            with self.assertRaises(ValueError):
                acceptance.validate_result(self.expected, result)

    def test_missing_runtime_fails_preflight_with_receipt(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "evidence"
            run = subprocess.run([sys.executable, "-B", str(Path(acceptance.__file__)),
                                  "--lean-root", str(root / "missing-lean"),
                                  "--source-imports", str(root / "missing-imports"),
                                  "--elixir", sys.executable, "--output-dir", str(output)],
                                 capture_output=True, timeout=20, check=False)
            self.assertNotEqual(run.returncode, 0)
            receipt = acceptance.loads((output / "summary.json").read_bytes())
            self.assertEqual((receipt["status"], receipt["failure_phase"], receipt["tests"]),
                             ("failed", "preflight", 0))
            self.assertEqual(set(receipt["required_cases"]), set(self.expected))

    def test_absent_real_recovery_evidence_cannot_pass(self):
        with TemporaryDirectory() as temporary, self.assertRaises(FileNotFoundError):
            acceptance.validate_evidence(Path(temporary), "0" * 64)


if __name__ == "__main__":
    unittest.main()
