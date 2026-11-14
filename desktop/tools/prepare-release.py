#!/usr/bin/env python3
"""Promote checked installer bytes; never rebuild or publish a release here."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

REQUIRED = {"Linux": {".deb", ".rpm", ".AppImage"}, "macOS": {".dmg"}, "Windows": {".msi", ".exe"}}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare(candidates, output, source_sha, tag, config_path):
    config = json.loads(config_path.read_text(encoding="utf-8"))
    version, identifier = config["version"], config["identifier"]
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or tag != "desktop-v" + version:
        raise ValueError("release tag, desktop version and exact source SHA must agree")
    if output.exists() and any(output.iterdir()):
        raise ValueError("release output must be empty")
    if candidates.is_symlink() or any(p.is_symlink() for p in candidates.rglob("*")):
        raise ValueError("symlink candidate refused")
    planned, all_names, manifests = [], set(), []
    expected_dirs = {f"biz-kit-{p}-{source_sha}" for p in REQUIRED}
    if {p.name for p in candidates.iterdir()} != expected_dirs:
        raise ValueError("exactly the three same-revision platform candidates are required")
    for platform, extensions in REQUIRED.items():
        root = candidates / f"biz-kit-{platform}-{source_sha}"
        manifest = json.loads((root / "provenance.json").read_text(encoding="utf-8"))
        expected = {"schemaVersion": 2, "sourceSha": source_sha, "platform": platform,
                    "desktopVersion": version, "appIdentifier": identifier,
                    "publication": "candidate", "distributionSigning": "not_configured"}
        if any(manifest.get(k) != v for k, v in expected.items()):
            raise ValueError(f"{platform}: stale or incompatible candidate provenance")
        artifacts = manifest.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            raise ValueError("missing installer inventory")
        local_names, suffixes, sums = set(), set(), []
        for item in artifacts:
            name = item.get("file")
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
                raise ValueError("unsafe installer name")
            if name in all_names or Path(name).suffix not in extensions:
                raise ValueError("duplicate or unsupported installer")
            path = root / name
            if not path.is_file() or type(item.get("bytes")) is not int or item["bytes"] <= 0:
                raise ValueError("missing or empty installer")
            if path.stat().st_size != item["bytes"] or digest(path) != item.get("sha256"):
                raise ValueError("installer bytes differ from the checked candidate")
            local_names.add(name); all_names.add(name); suffixes.add(path.suffix)
            sums.append(f'{item["sha256"]}  {name}\n')
            planned.append((path, name))
        if suffixes != extensions or {p.name for p in root.iterdir()} != local_names | {"provenance.json", "SHA256SUMS"}:
            raise ValueError("incomplete installer set or unlisted candidate file")
        if (root / "SHA256SUMS").read_text(encoding="utf-8") != "".join(sums):
            raise ValueError("candidate checksum inventory mismatch")
        manifests.append(manifest)
        planned.append((root / "provenance.json", f"provenance-{platform}.json"))
    # Validate everything before writing any proposed release asset.
    output.mkdir(parents=True, exist_ok=True)
    for source, name in planned:
        shutil.copyfile(source, output / name)
        if digest(source) != digest(output / name):
            raise ValueError("copy verification failed")
    result = {"schemaVersion": 1, "sourceSha": source_sha, "desktopVersion": version,
              "appIdentifier": identifier, "tag": tag, "publication": "draft",
              "distributionSigning": "not_configured", "candidates": manifests}
    (output / "desktop-release.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    (output / "SHA256SUMS").write_text("".join(f"{digest(p)}  {p.name}\n" for p in sorted(output.iterdir()) if p.is_file() and p.name != "SHA256SUMS"), encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / "src-tauri/tauri.conf.json")
    a = parser.parse_args()
    print(json.dumps(prepare(a.candidates, a.output, a.source_sha, a.tag, a.config), indent=2))
