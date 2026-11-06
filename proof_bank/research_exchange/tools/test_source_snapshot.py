"""Adversarial checks for the local source gate, separate from mathematical proofs."""
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from source_snapshot import MANIFEST, canonical, digest_bytes, verify_manifest, write_manifest
from runtime_identity import tree_identity


class SourceGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "model.lean").write_text("theorem identity (p : Prop) (h : p) : p := h\n")
        self.digest = write_manifest(self.root)

    def test_unchanged_source_accepted(self):
        self.assertEqual(len(verify_manifest(self.root, self.digest)["files"]), 1)

    def test_changed_source_rejected(self):
        (self.root / "model.lean").write_text("axiom invented : False\n")
        with self.assertRaisesRegex(ValueError, "reviewed source differs"):
            verify_manifest(self.root, self.digest)

    def test_added_source_rejected(self):
        (self.root / "unexpected.lean").write_text("import Lean\n")
        with self.assertRaisesRegex(ValueError, "unexpected.lean"):
            verify_manifest(self.root, self.digest)

    def test_removed_source_rejected(self):
        (self.root / "model.lean").unlink()
        with self.assertRaisesRegex(ValueError, "model.lean"):
            verify_manifest(self.root, self.digest)

    def test_new_manifest_does_not_authorize_itself(self):
        (self.root / "model.lean").write_text("axiom invented : False\n")
        changed = write_manifest(self.root)
        self.assertNotEqual(changed, self.digest)
        with self.assertRaisesRegex(ValueError, "caller's reviewed digest"):
            verify_manifest(self.root, self.digest)

    def test_manifest_encoding_is_exact(self):
        path = self.root / MANIFEST
        data = json.dumps(json.loads(path.read_bytes()), indent=2).encode()
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "canonical byte encoding"):
            verify_manifest(self.root, digest_bytes(data))

    def test_source_symlink_rejected(self):
        (self.root / "redirect.lean").symlink_to(self.root / "model.lean")
        with self.assertRaisesRegex(ValueError, "symlink refused"):
            verify_manifest(self.root, self.digest)

    def test_evidence_does_not_change_source_identity(self):
        (self.root / "evidence").mkdir()
        (self.root / "evidence/run.json").write_text('{"status":"failed"}')
        self.assertEqual(len(verify_manifest(self.root, self.digest)["files"]), 1)

    def test_invalid_digest_rejected(self):
        with self.assertRaisesRegex(ValueError, "64 lowercase"):
            verify_manifest(self.root, "not-a-digest")

    def test_distribution_change_detected(self):
        before = tree_identity(self.root)
        (self.root / "model.lean").write_text("changed\n")
        self.assertNotEqual(tree_identity(self.root)["sha256"], before["sha256"])

    def test_runtime_external_symlink_rejected(self):
        (self.root / "outside").symlink_to(Path(__file__).resolve())
        with self.assertRaisesRegex(ValueError, "escapes distribution"):
            tree_identity(self.root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
