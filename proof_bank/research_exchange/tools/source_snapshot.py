#!/usr/bin/env python3
"""Content-address the reviewed source; generated evidence is kept separately."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SCHEMA = "formal-research-exchange/source-snapshot/v1"
MANIFEST = "SOURCE_MANIFEST.json"
EXCLUDED_DIRECTORIES = {".git", ".lake", "__pycache__", "evidence", "dist", "node_modules"}


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("utf-8")


def inventory(root: Path) -> list[dict[str, object]]:
    result = []
    for item in sorted(root.rglob("*")):
        relative = item.relative_to(root)
        if any(part in EXCLUDED_DIRECTORIES for part in relative.parts):
            continue
        if relative.as_posix() == MANIFEST:
            continue
        if item.is_symlink():
            raise ValueError(f"source symlink refused: {relative}")
        if item.is_file():
            data = item.read_bytes()
            result.append({"path": relative.as_posix(), "bytes": len(data), "sha256": digest_bytes(data)})
    return result


def make_manifest(root: Path) -> dict[str, object]:
    return {"schema": SCHEMA, "files": inventory(root)}


def write_manifest(root: Path) -> str:
    data = canonical(make_manifest(root))
    (root / MANIFEST).write_bytes(data)
    return digest_bytes(data)


def verify_manifest(root: Path, expected_digest: str) -> dict[str, object]:
    if len(expected_digest) != 64 or any(c not in "0123456789abcdef" for c in expected_digest):
        raise ValueError("reviewed source digest must be 64 lowercase hexadecimal characters")
    data = (root / MANIFEST).read_bytes()
    if digest_bytes(data) != expected_digest:
        raise ValueError("source-manifest digest does not match the caller's reviewed digest")
    manifest = json.loads(data)
    if manifest.get("schema") != SCHEMA:
        raise ValueError("unsupported source-manifest schema")
    if data != canonical(manifest):
        raise ValueError("source manifest is not in the required canonical byte encoding")
    actual = inventory(root)
    if manifest.get("files") != actual:
        before = {x["path"]: x for x in manifest.get("files", [])}
        after = {x["path"]: x for x in actual}
        changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
        raise ValueError("reviewed source differs: " + ", ".join(changed[:20]))
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["create", "verify"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--expected-source-sha256")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.operation == "create":
        print(write_manifest(root))
    else:
        if args.expected_source_sha256 is None:
            parser.error("verify requires --expected-source-sha256")
        result = verify_manifest(root, args.expected_source_sha256)
        print(json.dumps({"source_sha256": args.expected_source_sha256, "files": len(result["files"])}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
