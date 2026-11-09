"""Adversarial acceptance tests for the evidence gate, not the offset algorithm."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("setoff_verifier", Path(__file__).with_name("verify.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ReceiptGuards(unittest.TestCase):
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
