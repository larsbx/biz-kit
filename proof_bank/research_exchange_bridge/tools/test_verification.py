"""Refusal controls for the complete-stage requirement."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("bridge_verify", Path(__file__).with_name("verify.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class CompleteProfileTests(unittest.TestCase):
    # Independent contract: deriving these names from verify.REQUIRED would let
    # deletion of a required stage silently weaken both implementation and test.
    expected = ("proofs", "models", "reviewed_profile", "runtime_acceptance",
                "source_acceptance", "representation_conformance")

    def stages(self):
        return [{"id": name, "status": "passed", "exit_code": 0} for name in self.expected]

    def test_complete_profile_required(self):
        self.assertTrue(verify.acceptance_passed(self.stages()))
        self.assertEqual(verify.REQUIRED, self.expected)
        for index in range(len(self.expected)):
            stages = self.stages()
            del stages[index]
            self.assertFalse(verify.acceptance_passed(stages))

    def test_skipped_failed_and_inconsistent_success_refused(self):
        for index in range(len(self.expected)):
            for status, code in (("skipped", 0), ("failed", 0), ("passed", 1)):
                stages = self.stages()
                stages[index].update(status=status, exit_code=code)
                self.assertFalse(verify.acceptance_passed(stages))

    def test_extra_reordered_or_duplicate_stages_refused(self):
        stages = self.stages()
        self.assertFalse(verify.acceptance_passed(stages + stages[:1]))
        self.assertFalse(verify.acceptance_passed(list(reversed(stages))))
        stages[1] = stages[0]
        self.assertFalse(verify.acceptance_passed(stages))

    def test_export_only_success_cannot_accept_source_integration(self):
        prior_profile = [stage for stage in self.stages() if stage["id"] != "source_acceptance"]
        self.assertFalse(verify.acceptance_passed(prior_profile))


if __name__ == "__main__":
    unittest.main()
