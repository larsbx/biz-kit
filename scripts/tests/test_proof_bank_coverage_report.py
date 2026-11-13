"""Tests for conservative first-party coverage reporting."""
import hashlib
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

source = Path(__file__).resolve().parents[1] / "proof_bank_coverage_report.py"
spec = importlib.util.spec_from_file_location("coverage_report", source)
# Import the sibling static audit explicitly when loaded outside a package.
import sys
sys.path.insert(0, str(source.parent))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\\0" + data).hexdigest()


class CoverageReportTest(unittest.TestCase):
    def setUp(self):
        self.work = TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        root = self.root = Path(self.work.name)
        (root / "apps/example").mkdir(parents=True)
        (root / "apps/example/mix.exs").write_bytes(b"example")
        (root / "mix.exs").write_bytes(b"platform")
        statuses = {
            "review_status": "needs_owner_review",
            "test_result": "not_executed",
            "implementation_conformance": "not_established",
            "proof_status": "not_proven",
            "runtime_conformance": "not_established",
        }

        def record(name, path):
            return dict(
                schema="biz-kit.proof-bank.characterization.v1",
                id=name, source_sha="pinned",
                intended_purpose="First-party source package",
                first_formal_obligation="No unauthorized effect",
                first_formal_layer="L2",
                observed_code_paths=[path],
                observed_test_path=None,
                evidence_git_blobs={path: blob((root / path).read_bytes())},
                **statuses
            )

        self.catalog = {
            "schema": "biz-kit.proof-bank.characterizations.v1",
            "source_sha": "pinned",
            "records": [record("example", "apps/example/mix.exs"), record("biz-kit", "mix.exs")],
        }

    def test_does_not_promote_unreviewed_records(self):
        report = module.build(self.root, self.catalog)
        self.assertEqual(report["catalog_entries"], 2)
        self.assertEqual(report["applications"], 1)
        self.assertEqual(report["entries_with_test_leads"], 0)
        self.assertEqual(report["owner_review_pending"], 2)
        self.assertEqual(report["proofs_established_by_this_report"], 0)
        self.assertIn("NOT a test-run result", module.markdown(report))

    def test_tampered_source_fails_closed(self):
        (self.root / "apps/example/mix.exs").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "changed source/test bytes"):
            module.build(self.root, self.catalog)

    def test_forged_proof_status_fails_closed(self):
        self.catalog["records"][0]["proof_status"] = "proven"
        with self.assertRaisesRegex(ValueError, "invalid status proof_status"):
            module.build(self.root, self.catalog)

    def test_missing_application_fails_closed(self):
        self.catalog["records"].pop(0)
        with self.assertRaisesRegex(ValueError, "app drift"):
            module.build(self.root, self.catalog)


if __name__ == "__main__":
    unittest.main()
