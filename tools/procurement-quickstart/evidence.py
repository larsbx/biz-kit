#!/usr/bin/env python3
"""Check integrity/completeness of an unsigned, local execution observation.

A self-consistent bundle can be fabricated. This checks neither an issuer's
identity nor the truth of supplied logs; trust the runner separately.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re

STAGES = frozenset({"preflight", "formal", "database", "runtime", "receipt", "cleanup"})
CHECKS = frozenset({
    "packaged_identity", "migration", "unauthenticated_denied", "csrf_denied",
    "http_lifecycle", "obsolete_quote_denied", "exact_retry_inert", "restart_replay",
    "revoked_session_denied", "revoked_write_inert", "backup_restore_equal",
    "restored_revocation_denied",
})
TRUST = "unsigned-runner-observation"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def regular_file(root: Path, name: str) -> Path:
    relative = Path(name)
    require(not relative.is_absolute() and relative.parts and
            all(part not in {".", ".."} for part in relative.parts), "unsafe evidence path")
    path = root / relative
    require(all(not parent.is_symlink() for parent in [path, *path.parents] if parent != root.parent),
            "symlink in evidence path")
    require(path.is_file() and path.resolve().is_relative_to(root.resolve()), "missing evidence file: " + name)
    return path


def packaged(root: Path, revision: str) -> dict:
    receipt = json.loads(regular_file(root, "host/release/receipt.json").read_text())
    archive = regular_file(root, "host/procurement-release.tar.gz")
    require(receipt.get("kind") == "procurement-packaged-acceptance-v1", "wrong packaged receipt kind")
    require(receipt.get("revision") == revision, "packaged revision mismatch")
    require(receipt.get("artifact_sha256") == sha256(archive), "packaged archive digest mismatch")
    require(receipt.get("trust") == TRUST, "wrong packaged trust label")
    checks = receipt.get("checks")
    require(isinstance(checks, dict) and set(checks) == CHECKS and
            all(value is True for value in checks.values()), "missing, extra, failed or skipped packaged checks")
    return receipt


def write_manifest(root: Path) -> None:
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and path != root / "manifest.json":
            name = path.relative_to(root).as_posix()
            files[name] = sha256(regular_file(root, name))
    (root / "manifest.json").write_text(json.dumps({"sha256": files}, indent=2, sort_keys=True) + "\n")


def verify(root: Path, revision: str) -> dict:
    require(bool(re.fullmatch(r"[0-9a-f]{40}", revision)), "a full expected commit SHA is required")
    result = json.loads(regular_file(root, "result.json").read_text())
    require(result.get("kind") == "procurement-quickstart-v1", "wrong quick-start result kind")
    require(result.get("revision") == revision, "quick-start revision mismatch")
    require(result.get("trust") == TRUST, "wrong quick-start trust label")
    require(result.get("status") == "passed", "run failed or did not finish")
    require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", result.get("image_id", ""))), "missing image identity")
    stages = result.get("stages")
    require(isinstance(stages, dict) and set(stages) == STAGES and
            all(value is True for value in stages.values()), "missing, skipped or failed execution stage")
    manifest = json.loads(regular_file(root, "manifest.json").read_text()).get("sha256")
    require(isinstance(manifest, dict), "missing digest manifest")
    actual = {p.relative_to(root).as_posix() for p in root.rglob("*")
              if p.is_file() and p != root / "manifest.json"}
    require(set(manifest) == actual, "manifest inventory mismatch")
    required = {"result.json", "toolchain.log", "database.log", "runtime.log", "cleanup.log",
                "host/release/receipt.json", "host/procurement-release.tar.gz"}
    required.update(f"formal/{name}.log" for name in
                    ("Workflow", "Admission", "workflow-typecheck", "workflow-tests", "workflow-run",
                     "admission-typecheck", "admission-tests", "admission-run"))
    require(required <= actual, "required execution log missing")
    for name, expected in manifest.items():
        require(sha256(regular_file(root, name)) == expected, "evidence digest mismatch: " + name)
    packaged(root, revision)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        result = verify(args.directory.resolve(), args.revision)
    except (ValueError, OSError, TypeError) as error:
        parser.exit(1, f"NOT ACCEPTED: {error}\n")
    print(f"Complete unsigned execution bundle for {result['revision']}; not deployment approval.")


if __name__ == "__main__":
    main()
