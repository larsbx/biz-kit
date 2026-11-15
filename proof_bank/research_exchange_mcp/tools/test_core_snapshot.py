"""Refusal controls for the shared receipt/core/CI source identity boundary."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from verify_core_snapshot import load_snapshot, verify_snapshot
from source_snapshot import canonical, make_manifest


class CoreSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.core = self.root / "core"
        self.core.mkdir()
        (self.core / "model.lean").write_text("theorem fixture : True := True.intro\n")
        self.manifest = canonical(make_manifest(self.core))
        (self.core / "SOURCE_MANIFEST.json").write_bytes(self.manifest)
        self.snapshot = self.root / "CORE_SNAPSHOT.json"
        self.identity = {
            "revision": "a" * 40,
            "source_manifest_sha256": hashlib.sha256(self.manifest).hexdigest(),
        }
        self.write(self.identity)

    def write(self, identity):
        self.snapshot.write_text(json.dumps(identity), encoding="utf-8")

    def verify(self, approved_manifest=None):
        return verify_snapshot(
            self.core,
            self.snapshot,
            approved_manifest=self.manifest if approved_manifest is None else approved_manifest,
        )

    def test_same_reviewed_revision_manifest_and_source_pass(self):
        result = self.verify()
        self.assertEqual(result["reviewed_core"], self.identity)
        self.assertEqual(result["source_files"], 1)

    def test_historical_revision_with_different_manifest_is_refused(self):
        with self.assertRaisesRegex(ValueError, "Git revision"):
            self.verify(b"a different historical manifest\n")

    def test_stale_manifest_pin_is_refused(self):
        self.write({**self.identity, "source_manifest_sha256": "0" * 64})
        with self.assertRaisesRegex(ValueError, "Git revision"):
            self.verify()

    def test_changed_source_with_unchanged_manifest_is_refused(self):
        (self.core / "model.lean").write_text("axiom fixture : False\n")
        with self.assertRaisesRegex(ValueError, "reviewed source differs"):
            self.verify()

    def test_extra_source_is_refused(self):
        (self.core / "extra.lean").write_text("axiom extra : False\n")
        with self.assertRaisesRegex(ValueError, "reviewed source differs"):
            self.verify()

    def test_duplicate_fields_are_refused(self):
        self.snapshot.write_text(
            '{"revision":"' + "a" * 40 + '","revision":"' + "b" * 40
            + '","source_manifest_sha256":"' + self.identity["source_manifest_sha256"] + '"}'
        )
        with self.assertRaisesRegex(ValueError, "duplicate"):
            load_snapshot(self.snapshot)

    def test_identity_schema_and_hex_fields_are_strict(self):
        for identity in [
            [], {}, {**self.identity, "trusted": True},
            {**self.identity, "revision": "main"},
            {**self.identity, "revision": "A" * 40},
            {**self.identity, "revision": "a" * 40 + "\n"},
            {**self.identity, "source_manifest_sha256": 1},
            {**self.identity, "source_manifest_sha256": "e" * 63},
        ]:
            with self.subTest(identity=identity):
                self.write(identity)
                with self.assertRaises(ValueError):
                    load_snapshot(self.snapshot)


if __name__ == "__main__":
    unittest.main()
