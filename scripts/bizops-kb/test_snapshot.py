#!/usr/bin/env python3
"""Negative controls for the offline source-provenance and update boundary."""

import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import snapshot


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "snapshot"
        shutil.copytree(snapshot.DEFAULT_ROOT, self.root)

    def read(self, name):
        return json.loads((self.root / name).read_text())

    def write(self, name, value):
        snapshot.write_json(self.root / name, value)

    def test_committed_snapshot_has_verified_source_and_resolved_links(self):
        result = snapshot.check(self.root)
        self.assertEqual(result["documents"], 216)
        self.assertEqual(result["wikilinks"], 45)
        self.assertEqual(result["revision"], "ca356e34e6b1c4a2fb9f576c34196ca3bf13beee")

    def test_changed_content_cannot_rewrite_its_catalog_hash_to_pass(self):
        catalog = self.read("catalog.json")
        document = catalog["documents"][0]
        body = b"Changed content\n"
        (self.root / "content" / document["path"]).write_bytes(body)
        document.update(size=len(body), sha256=hashlib.sha256(body).hexdigest(), blob_sha=snapshot.object_hash("blob", body))
        self.write("catalog.json", catalog)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "source blob mismatch"):
            snapshot.check(self.root)

    def test_changed_tree_membership_is_detected(self):
        proof = self.read("source-proof.json")
        proof["entries"][0]["sha"] = "0" * 40
        self.write("source-proof.json", proof)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "source tree hash mismatch"):
            snapshot.check(self.root)

    def test_altered_source_commit_is_detected(self):
        proof = self.read("source-proof.json")
        proof["commit_base64"] = base64.b64encode(base64.b64decode(proof["commit_base64"]) + b"changed").decode()
        self.write("source-proof.json", proof)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "source commit hash mismatch"):
            snapshot.check(self.root)

    def test_document_identity_cannot_be_silently_changed(self):
        catalog = self.read("catalog.json")
        catalog["documents"][0]["id"] = "24.12a"
        self.write("catalog.json", catalog)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "catalog differs"):
            snapshot.check(self.root)

    def test_added_unpinned_file_is_refused(self):
        (self.root / "content" / "unreviewed.md").write_text("# Extra\n")
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "inventory differs"):
            snapshot.check(self.root)

    def test_symlink_does_not_escape_content_root(self):
        document = self.read("catalog.json")["documents"][0]
        path = self.root / "content" / document["path"]
        outside = self.root / "outside.md"
        outside.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(outside)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "symlink in content"):
            snapshot.check(self.root)

    def test_unsafe_and_duplicate_source_paths_are_refused(self):
        for path in ("../escape.md", "/absolute.md", "safe/../escape.md", "safe\\escape.md", "safe//escape.md", "C:/escape.md"):
            with self.subTest(path=path), self.assertRaises(snapshot.InvalidSnapshot):
                snapshot.tree_hash([{"path": path, "mode": "100644", "sha": "0" * 40}])
        entry = {"path": "same.md", "mode": "100644", "sha": "0" * 40}
        with self.assertRaises(snapshot.InvalidSnapshot):
            snapshot.tree_hash([entry, entry])

    def test_duplicate_json_keys_are_refused(self):
        (self.root / "catalog.json").write_text('{"schema":1,"schema":2}')
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "duplicate JSON key"):
            snapshot.check(self.root)

    def test_oversized_document_is_rejected_before_reading(self):
        path = self.root / "content" / self.read("catalog.json")["documents"][0]["path"]
        with path.open("wb") as handle:
            handle.truncate(snapshot.MAX_DOCUMENT_BYTES + 1)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "exceeds byte limit"):
            snapshot.check(self.root)

    def test_fifo_is_rejected_without_waiting_for_a_writer(self):
        path = self.root / "content" / self.read("catalog.json")["documents"][0]["path"]
        path.unlink()
        os.mkfifo(path)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "not regular"):
            snapshot.check(self.root)

    def test_oversized_metadata_is_rejected_before_decoding(self):
        with (self.root / "catalog.json").open("wb") as handle:
            handle.truncate(snapshot.MAX_METADATA_BYTES + 1)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "exceeds byte limit"):
            snapshot.check(self.root)

    def test_reproducible_import_preserves_unicode_ids_and_refuses_local_edits(self):
        source = Path(self.temporary.name) / "source"
        source.mkdir()
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        snapshot.git(source, "config", "core.autocrlf", "false")
        path = "20-29 Products/24 Processes 📋/24.12a Geräte & team 🧭.md"
        (source / path).parent.mkdir(parents=True)
        (source / path).write_text("# Geräte\n\nAn inert procedure.\n", encoding="utf-8")
        (source / "README.md").write_text("[[24.12a Geräte & team 🧭]]\n", encoding="utf-8")
        (source / "settings.json").write_text('{"not_published":true}\n')
        snapshot.git(source, "add", ".")
        tree = snapshot.git(source, "write-tree").decode().strip()
        raw = f"tree {tree}\nauthor Fixture <fixture@example.invalid> 0 +0000\ncommitter Fixture <fixture@example.invalid> 0 +0000\n\nSource fixture\n".encode()
        revision = subprocess.run(["git", "-C", str(source), "hash-object", "-w", "-t", "commit", "--stdin"], input=raw, stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        target = Path(self.temporary.name) / "imported"
        snapshot.import_snapshot(source, revision, target)
        original = (target / "catalog.json").read_bytes()
        snapshot.import_snapshot(source, revision, target)
        self.assertEqual((target / "catalog.json").read_bytes(), original)
        manifest = json.loads(original)
        self.assertEqual(manifest["documents"][0]["id"], "24.12a")
        self.assertEqual((target / "content" / path).read_bytes(), (source / path).read_bytes())
        self.assertFalse((target / "content/settings.json").exists())
        (target / "content" / path).write_text("Local edit")
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "source blob mismatch"):
            snapshot.import_snapshot(source, revision, target)
        with self.assertRaisesRegex(snapshot.InvalidSnapshot, "exact 40-character"):
            snapshot.import_snapshot(source, "main", target)


if __name__ == "__main__":
    unittest.main()
