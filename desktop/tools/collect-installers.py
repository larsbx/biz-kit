#!/usr/bin/env python3
"""Collect complete native installer sets with exact-source SHA-256 provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

REQUIRED = {"Linux": {".deb", ".rpm", ".AppImage"}, "macOS": {".dmg"}, "Windows": {".msi", ".exe"}}
CONFIG = Path(__file__).resolve().parents[1] / "src-tauri/tauri.conf.json"


def collect(bundle_root, output, platform, source_sha, config_path=CONFIG):
    if platform not in REQUIRED or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("platform and exact 40-character source SHA are required")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    version, identifier = config.get("version"), config.get("identifier")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version) or not identifier:
        raise ValueError("a stable desktop version and application identifier are required")
    files = sorted(p for p in bundle_root.rglob("*") if p.is_file()
                   and "release/bundle/" in p.as_posix() and p.suffix in REQUIRED[platform])
    found = {p.suffix for p in files}
    if found != REQUIRED[platform]:
        raise ValueError(f"incomplete {platform} installer set: missing {sorted(REQUIRED[platform] - found)}")
    if any(p.is_symlink() or p.stat().st_size == 0 for p in files):
        raise ValueError("empty or symlink installer")
    if len({p.name for p in files}) != len(files):
        raise ValueError("installer filename collision")
    if output.exists() and any(output.iterdir()):
        raise ValueError("output must be empty; refusing stale installer artifacts")
    output.mkdir(parents=True, exist_ok=True)
    artifacts = []
    for path in files:
        target = output / path.name
        shutil.copyfile(path, target)
        with target.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        artifacts.append({"file": target.name, "bytes": target.stat().st_size, "sha256": digest})
    manifest = {"schemaVersion": 2, "sourceSha": source_sha, "platform": platform,
                "desktopVersion": version, "appIdentifier": identifier,
                "publication": "candidate", "distributionSigning": "not_configured", "artifacts": artifacts}
    (output / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    (output / "SHA256SUMS").write_text("".join(f'{a["sha256"]}  {a["file"]}\n' for a in artifacts), encoding="utf-8", newline="\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=REQUIRED, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    print(json.dumps(collect(args.bundle_root, args.output, args.platform, args.source_sha), indent=2))
