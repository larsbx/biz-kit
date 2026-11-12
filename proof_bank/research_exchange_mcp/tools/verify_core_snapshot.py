#!/usr/bin/env python3
"""Bind MCP receipt identity and exchange CI to one reviewed core snapshot.

The historical revision identifies the reviewed core source, not the commit
running this adapter. Verify its manifest against both the selected digest and
the complete current core inventory. Never create or repin a source manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

PACKAGE = Path(__file__).resolve().parents[1]
REPOSITORY = PACKAGE.parents[1]
CORE = PACKAGE.parent / "research_exchange"
SNAPSHOT = PACKAGE / "CORE_SNAPSHOT.json"
SOURCE_PATH = "proof_bank/research_exchange/SOURCE_MANIFEST.json"
REVIEW_PATHS = [
    "proof_bank/research_exchange",
    "proof_bank/research_exchange_mcp",
    "proof_bank/research_exchange_bridge",
    "docs/proof-bank/research-exchange",
    ".github/workflows/proof-bank-research-exchange.yml",
    ".github/workflows/research-exchange-adapter.yml",
    ".github/workflows/research-exchange-durable-bridge.yml",
]

sys.dont_write_bytecode = True
sys.path.insert(0, str(CORE / "tools"))
from source_snapshot import verify_manifest  # noqa: E402


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate core snapshot field: {key}")
        value[key] = item
    return value


def load_snapshot(path: Path = SNAPSHOT) -> dict[str, str]:
    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != {"revision", "source_manifest_sha256"}:
        raise ValueError("core snapshot requires exactly revision and source_manifest_sha256")
    for key, length in [("revision", 40), ("source_manifest_sha256", 64)]:
        if not isinstance(value[key], str) or re.fullmatch(rf"[0-9a-f]{{{length}}}", value[key]) is None:
            raise ValueError(f"invalid core snapshot {key}")
    return value


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], cwd=REPOSITORY)


def verify_snapshot(
    core: Path = CORE,
    snapshot_path: Path = SNAPSHOT,
    *,
    approved_manifest: bytes | None = None,
) -> dict:
    snapshot = load_snapshot(snapshot_path)
    if approved_manifest is None:
        approved_manifest = git("show", f"{snapshot['revision']}:{SOURCE_PATH}")
    digest = snapshot["source_manifest_sha256"]
    if hashlib.sha256(approved_manifest).hexdigest() != digest:
        raise ValueError("reviewed Git revision does not contain the selected core manifest")
    manifest = verify_manifest(core, digest)
    return {
        "schema": "research-exchange/core-snapshot-check/v1",
        "status": "passed",
        "reviewed_core": snapshot,
        "source_files": len(manifest["files"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-revision", action="store_true")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--github-env", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.print_revision:
            if args.require_clean or args.github_env or args.output:
                raise ValueError("--print-revision cannot be combined with verification options")
            print(load_snapshot()["revision"])
            return 0
        record = verify_snapshot()
        changed = git("status", "--porcelain=v1", "--untracked-files=all", "--", *REVIEW_PATHS)
        if args.require_clean and changed:
            raise ValueError("reviewed exchange source differs from the checked-out Git commit")
        record.update({
            "git_commit": git("rev-parse", "HEAD").decode().strip(),
            "git_tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
            "exchange_source_matches_commit": not bool(changed),
            "workflow_ref": os.environ.get("GITHUB_WORKFLOW_REF"),
            "workflow_sha": os.environ.get("GITHUB_WORKFLOW_SHA"),
        })
        encoded = json.dumps(record, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded, encoding="utf-8")
        if args.github_env:
            # These values passed strict lowercase-hex validation above.
            with args.github_env.open("a", encoding="utf-8") as out:
                out.write(f"FRE_SOURCE_SHA256={record['reviewed_core']['source_manifest_sha256']}\n")
                out.write(f"FRE_CORE_REVISION={record['reviewed_core']['revision']}\n")
        print(encoded, end="")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"CORE_SNAPSHOT_REFUSED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
