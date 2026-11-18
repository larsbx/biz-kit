"""Negative controls for source-specific ExUnit mutation evidence."""
import copy
from pathlib import Path
import types
import unittest


checker_path = Path(__file__).with_name("assertion_mutations.py")
checker = types.ModuleType("assertion_mutations")
checker.__file__ = str(checker_path)
exec(compile(checker_path.read_bytes(), str(checker_path), "exec"), checker.__dict__)


class AssertionMutationGuards(unittest.TestCase):
    def baseline(self):
        ids = ["Fixture:test intended", "Fixture:test unrelated", "Fixture:test second file"]
        return {"schema": "bizkit.cross-currency.assertion-suite.v1",
                "suite_started": 1, "suite_finished": 1, "interrupted": False,
                "declared": [{"id": test, "file": "a.exs" if i < 2 else "b.exs"}
                             for i, test in enumerate(ids)],
                "started": ids,
                "finished": [{"id": test, "status": "passed", "failure_classes": []} for test in ids]}

    def mutation(self, index=0, error="ExUnit.AssertionError"):
        report = self.baseline()
        report["finished"][index].update(status="failed", failure_classes=[error])
        return report

    def check(self, report, baseline=None, required=None):
        return checker.validate_mutant(report, baseline or self.baseline(), ["a.exs", "b.exs"],
                                       required if required is not None else ["Fixture:test intended"])

    def test_passing_baseline_and_intended_assertion_are_accepted(self):
        self.assertEqual(len(checker.validate_baseline(self.baseline(), ["a.exs", "b.exs"])), 3)
        self.assertEqual(self.check(self.mutation()), ["Fixture:test intended"])

    def test_unrelated_assertion_failure_is_not_mutant_detection(self):
        with self.assertRaisesRegex(ValueError, "intended source-specific assertion"):
            self.check(self.mutation(index=1))

    def test_nonpassing_identical_invocation_baseline_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "baseline must pass"):
            self.check(self.mutation(), baseline=self.mutation(index=1))

    def test_runtime_error_and_nonassertion_failure_are_rejected(self):
        for error in ["error:RuntimeError", "error:UndefinedFunctionError", "unknown", "exit:shutdown"]:
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, "non-assertion"):
                self.check(self.mutation(error=error))

    def test_missing_duplicate_substituted_and_skipped_tests_are_rejected(self):
        for field in ["declared", "started", "finished"]:
            for action in ["drop", "duplicate"]:
                report = self.mutation()
                if action == "drop":
                    report[field].pop()
                else:
                    report[field][1] = copy.deepcopy(report[field][0])
                with self.subTest(field=field, action=action), self.assertRaises(ValueError):
                    self.check(report)
        for status in ["skipped", "excluded", "unknown", "invalid"]:
            report = self.mutation()
            report["finished"][1]["status"] = status
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.check(report)
        report = self.mutation()
        report["declared"][1]["id"] = "Fixture:test substituted"
        report["started"][1] = "Fixture:test substituted"
        report["finished"][1]["id"] = "Fixture:test substituted"
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            self.check(report)

    def test_incomplete_suite_and_wrong_file_mapping_are_rejected(self):
        for changed in [{"suite_started": 0}, {"suite_finished": 0}, {"suite_finished": True},
                        {"interrupted": True}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.check(self.mutation() | changed)
        report = self.mutation()
        report["declared"][0]["file"] = "b.exs"
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            self.check(report)

    def test_unknown_empty_or_duplicate_required_id_cannot_pass(self):
        for required in [[], ["Fixture:test missing"], ["Fixture:test intended"] * 2,
                         ["Fixture:test intended", "Fixture:test unrelated"]]:
            with self.subTest(required=required), self.assertRaises(ValueError):
                self.check(self.mutation(), required=required)


if __name__ == "__main__":
    unittest.main(verbosity=2)
