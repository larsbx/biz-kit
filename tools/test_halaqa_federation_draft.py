"""Reject altered reference files and pin scope/path amplification."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "check_halaqa_federation_draft", ROOT / "tools/check_halaqa_federation_draft.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class HalaqaFederationPinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "tools/halaqa_federation_draft"
        shutil.copytree(ROOT / "tools/halaqa_federation_draft", self.directory)

    def alter_pin(self, function):
        path = self.directory / "source-pin.json"
        pin = json.loads(path.read_text())
        function(pin)
        path.write_text(json.dumps(pin))

    def test_pinned_corpus(self):
        result = checker.check(self.root)
        self.assertEqual(result["scope"], "offline-format-only")
        self.assertFalse(result["production_receiver"])
        self.assertEqual(result["counts"], {
            "FORMAT_ONLY_UNVERIFIED": 6, "REFUSED_FORMAT": 34})
        self.assertEqual(result["signed_experiment"]["counts"], {
            "SIGNATURE_VALID_AUTHORITY_UNVERIFIED": 8, "REFUSED_SIGNED_TEST": 40})
        self.assertFalse(result["signed_experiment"]["authority_verified"])

    def test_source_or_fixture_change_refused_before_execution(self):
        for name in checker.SOURCE_PATHS:
            with self.subTest(name=name):
                path = self.directory / name
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                with self.assertRaisesRegex(ValueError, "pinned source mismatch"):
                    checker.check(self.root)
                path.write_bytes(original)

    def test_scope_amplification_refused(self):
        self.alter_pin(lambda p: p.update(scope="production-admission"))
        with self.assertRaisesRegex(ValueError, "invalid source pin"):
            checker.check(self.root)

    def test_path_substitution_refused(self):
        self.alter_pin(lambda p: p["files"]["vectors.json"].update(source_path="../../other"))
        with self.assertRaisesRegex(ValueError, "invalid source file entry"):
            checker.check(self.root)

    def test_missing_or_extra_source_file_refused(self):
        self.alter_pin(lambda p: p["files"].update(extra={}))
        with self.assertRaisesRegex(ValueError, "invalid source pin"):
            checker.check(self.root)

    def test_preloaded_dependency_cannot_replace_pinned_oracle(self):
        poison = object()
        with patch.dict(sys.modules, {"halaqa_federation_draft": poison}):
            result = checker.check(self.root)
            self.assertIs(sys.modules["halaqa_federation_draft"], poison)
            self.assertFalse(result["signed_experiment"]["authority_verified"])

    def test_missing_openssl_cannot_report_signature_success(self):
        with patch("subprocess.run", side_effect=OSError("unavailable")):
            with self.assertRaisesRegex(ValueError, "verification_backend"):
                checker.check(self.root)


if __name__ == "__main__":
    unittest.main()
