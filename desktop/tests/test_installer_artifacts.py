import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("installers", Path(__file__).resolve().parents[1] / "tools/collect-installers.py")
installers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installers)
SHA = "c" * 40


class InstallerArtifactsTest(unittest.TestCase):
    def test_each_platform_requires_a_complete_nonempty_set_and_exact_bytes(self):
        for platform, suffixes in installers.REQUIRED.items():
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / "target/release/bundle"
                root.mkdir(parents=True)
                for suffix in suffixes:
                    (root / ("installer" + suffix)).write_bytes(b"native\r\ninstaller\x00\xff")
                out = Path(tmp) / "output"
                manifest = installers.collect(Path(tmp) / "target", out, platform, SHA)
                self.assertEqual(manifest["sourceSha"], SHA)
                self.assertEqual(manifest, json.loads((out / "provenance.json").read_text()))
                self.assertEqual(len(manifest["artifacts"]), len(suffixes))
                for artifact in manifest["artifacts"]:
                    self.assertEqual(artifact["sha256"], hashlib.sha256((out / artifact["file"]).read_bytes()).hexdigest())
                with self.assertRaisesRegex(ValueError, "output must be empty"):
                    installers.collect(Path(tmp) / "target", out, platform, SHA)

    def test_missing_or_empty_installers_cannot_be_uploaded_as_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "release/bundle"
            root.mkdir(parents=True)
            (root / "only.deb").write_bytes(b"deb")
            with self.assertRaisesRegex(ValueError, "incomplete"):
                installers.collect(Path(tmp), Path(tmp) / "out", "Linux", SHA)
            (root / "app.rpm").touch()
            (root / "app.AppImage").write_bytes(b"image")
            with self.assertRaisesRegex(ValueError, "empty"):
                installers.collect(Path(tmp), Path(tmp) / "out", "Linux", SHA)

    def test_provenance_cannot_use_a_branch_name_or_short_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            for sha in ["main", "1234567", "x" * 40]:
                with self.assertRaises(ValueError):
                    installers.collect(Path(tmp), Path(tmp) / "out", "Linux", sha)


if __name__ == "__main__":
    unittest.main()
