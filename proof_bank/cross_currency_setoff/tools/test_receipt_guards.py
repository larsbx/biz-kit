"""Adversarial acceptance tests for the evidence gate, not the offset algorithm."""
import importlib.util
import copy
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("setoff_verifier", Path(__file__).with_name("verify.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ReceiptGuards(unittest.TestCase):
    def suite_receipt(self, count=2):
        names = [f"BarterCase:test current example {i}" for i in range(count)]
        return {"schema": "bizkit.cross-currency.barter-suite.v1", "suite_started": 1,
                "suite_finished": 1, "interrupted": False,
                "declared": [{"id": name, "file": "test/current_test.exs"} for name in names],
                "started": names,
                "finished": [{"id": name, "status": "passed"} for name in names]}

    def check_suite(self, receipt):
        return verifier.check_suite_receipt(receipt, ["test/current_test.exs"])

    def test_current_complete_suite_accepts_more_than_the_old_test_count(self):
        for count in [2, 55, 62, 72, 73]:
            with self.subTest(count=count):
                self.assertEqual(self.check_suite(self.suite_receipt(count))["tests"], count)

    def test_empty_incomplete_and_aborted_suites_are_rejected(self):
        for changed in [{"suite_started": 0}, {"suite_finished": 0}, {"suite_finished": True},
                        {"suite_finished": 2}, {"interrupted": True}, {"started": []},
                        {"finished": []}, {"schema": "invented"}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.check_suite(self.suite_receipt() | changed)
        with self.assertRaises(ValueError):
            self.check_suite(self.suite_receipt(0))

    def test_failures_skips_exclusions_and_invalid_tests_are_rejected(self):
        for status in ["failed", "skipped", "excluded", "invalid", "unknown", None, 0]:
            receipt = self.suite_receipt()
            receipt["finished"][0]["status"] = status
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.check_suite(receipt)

    def test_omitted_files_duplicate_and_substituted_test_lifecycles_are_rejected(self):
        receipt = self.suite_receipt()
        with self.assertRaisesRegex(ValueError, "file coverage"):
            verifier.check_suite_receipt(receipt, ["test/current_test.exs", "test/omitted_test.exs"])
        for field in ["declared", "started", "finished"]:
            for action in ["remove", "duplicate", "substitute"]:
                changed = copy.deepcopy(receipt)
                if action == "remove":
                    changed[field].pop()
                elif action == "duplicate":
                    changed[field][0] = changed[field][1]
                elif field == "started":
                    changed[field][0] = "Unrelated:test injected"
                else:
                    changed[field][0]["id"] = "Unrelated:test injected"
                with self.subTest(field=field, action=action), self.assertRaises(ValueError):
                    self.check_suite(changed)

    def test_malformed_structured_suite_receipts_are_rejected(self):
        for receipt in [None, [], {}, self.suite_receipt() | {"unexpected": True},
                        self.suite_receipt() | {"declared": [None]},
                        self.suite_receipt() | {"started": [None]},
                        self.suite_receipt() | {"finished": [None]}]:
            with self.subTest(receipt=receipt), self.assertRaises(ValueError):
                self.check_suite(receipt)

    def test_standard_axioms_are_accepted(self):
        self.assertEqual(verifier.audit_axioms(
            "'A' depends on axioms: [propext, Quot.sound, Classical.choice]\n", ["A"]),
            {"A": ["propext", "Quot.sound", "Classical.choice"]})

    def test_custom_placeholder_and_native_axioms_are_rejected(self):
        for axiom in ["sorryAx", "invented", "Lean.ofReduceBool"]:
            with self.subTest(axiom=axiom), self.assertRaisesRegex(ValueError, "unapproved axioms"):
                verifier.audit_axioms(f"'A' depends on axioms: [{axiom}]\n", ["A"])

    def test_missing_duplicate_and_extra_results_are_rejected(self):
        for text in ["", "'A' does not depend on any axioms\n" * 2,
                     "'A' does not depend on any axioms\n'B' does not depend on any axioms\n"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                verifier.audit_axioms(text, ["A"])

    def with_repo(self, action):
        with tempfile.TemporaryDirectory(prefix="setoff-receipt-control-") as directory:
            root = Path(directory)
            for command in [["init", "-q"], ["config", "user.name", "Receipt control"],
                            ["config", "user.email", "receipt-control@example.invalid"]]:
                subprocess.run(["git", *command], cwd=root, check=True, capture_output=True)
            (root / "tracked.ex").write_text("original source\n")
            (root / ".gitignore").write_text("ignored.ex\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True, capture_output=True)
            previous = verifier.ROOT
            try:
                verifier.ROOT = root
                action(root)
            finally:
                verifier.ROOT = previous

    def test_ignored_source_cannot_claim_clean_head(self):
        def action(root):
            (root / "ignored.ex").write_text("injected source\n")
            self.assertEqual(verifier.git("status", "--porcelain"), "")
            with self.assertRaisesRegex(ValueError, "not present in HEAD"):
                verifier.require_head_sources({"ignored.ex": verifier.sha(root / "ignored.ex")})
        self.with_repo(action)

    def test_changed_source_bytes_cannot_claim_head_identity(self):
        def action(root):
            verifier.require_head_sources({"tracked.ex": verifier.sha(root / "tracked.ex")})
            (root / "tracked.ex").write_text("changed source\n")
            with self.assertRaisesRegex(ValueError, "bytes differ from HEAD"):
                verifier.require_head_sources({"tracked.ex": verifier.sha(root / "tracked.ex")})
        self.with_repo(action)

    def test_inexact_conserved_output_and_false_refusal_are_rejected(self):
        for output in [(2, 7, 4, 3, 1), (1, 0, 0, 10, 5)]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                verifier.check_observations([(10, 5, 3, 2)], [output])


if __name__ == "__main__":
    unittest.main(verbosity=2)
