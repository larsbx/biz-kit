"""Prepare fixed reviewed proof exports and an exact approved local profile."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

from .checker import ControlledChecker
from .common import (ALTERNATE_THEOREM, EXPECTED_THEOREM, POLICY, PROFILE_MODULE,
                     PROFILE_SCHEMA, PilotError, canonical, digest, file_digest,
                     source_identity, validate_profile)


def prepare_fixture(package_root: Path, lean_root: Path, output_dir: Path,
                    application_path_adapter: Path | None = None) -> dict:
    package_root = Path(package_root).resolve(strict=True)
    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    checker = ControlledChecker(lean_root, package_root, application_path_adapter)
    lean_dir = package_root / "formal/lean"
    lean_path = lean_dir / ".lake/build/lib/lean"
    env = checker.environment(lean_path)
    source_files = source_identity(package_root)
    lake = checker.lean_root / "bin/lake"
    if file_digest(lake) != checker.lock["file_sha256"]["lake"]:
        raise PilotError(503, "checker_identity_mismatch")
    # Only the operator-reviewed repository module is compiled, before any
    # contributor input exists. Runtime checking never invokes lake or lean.
    build = subprocess.run([str(lake), "build", PROFILE_MODULE], cwd=lean_dir,
                           env=env, capture_output=True, timeout=180, check=False)
    if build.returncode != 0 or b"sorry" in build.stdout + build.stderr:
        raise RuntimeError("reviewed fixture build failed: " +
                           (build.stdout + build.stderr).decode(errors="replace"))
    with tempfile.TemporaryDirectory(prefix="exchange-axioms-") as directory:
        audit = Path(directory) / "FixtureAxioms.lean"
        audit.write_text(f"import {PROFILE_MODULE}\n#print axioms {EXPECTED_THEOREM}\n"
                         f"#print axioms {ALTERNATE_THEOREM}\n")
        result = subprocess.run([str(checker.paths["lean"]), str(audit)], cwd=lean_dir,
                                env=env, capture_output=True, timeout=60, check=False)
    if result.returncode != 0:
        raise RuntimeError("fixture axiom inspection failed")
    output = result.stdout.decode("utf-8")
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    dependencies = {}
    for match in re.finditer(pattern, output):
        if match[1] in dependencies:
            raise RuntimeError("duplicate fixture axiom result")
        deps = [] if match[2] is None else [s.strip() for s in match[2].split(",") if s.strip()]
        if not set(deps) <= set(POLICY["allowed_axioms"]):
            raise RuntimeError("fixture uses unapproved axioms")
        dependencies[match[1]] = sorted(deps)
    if set(dependencies) != {EXPECTED_THEOREM, ALTERNATE_THEOREM}:
        raise RuntimeError("missing fixture axiom result")
    exports = {}
    replay_receipts = {}
    for label, theorem in (("expected", EXPECTED_THEOREM), ("alternate", ALTERNATE_THEOREM)):
        exported = subprocess.run([str(checker.paths["leanexport"]), PROFILE_MODULE, "--", theorem],
                                  cwd=lean_dir, env=env, capture_output=True, timeout=60, check=False)
        if exported.returncode != 0 or not exported.stdout:
            raise RuntimeError("fixture export failed")
        exports[label] = exported.stdout
        replay_receipts[label] = checker.replay_export(exported.stdout)
        (output_dir / f"{label}.export").write_bytes(exported.stdout)
    if digest(exports["expected"]) == digest(exports["alternate"]):
        raise RuntimeError("wrong-target control must have distinct proof bytes")
    if source_identity(package_root) != source_files:
        raise RuntimeError("reviewed source changed during fixture preparation")
    profile = {
        "schema": PROFILE_SCHEMA, "module": PROFILE_MODULE, "theorem": EXPECTED_THEOREM,
        "source_files": source_files, "source_sha256": digest(canonical(source_files)),
        "artifact_sha256": digest(exports["expected"]), "artifact_bytes": len(exports["expected"]),
        "toolchain_lock_sha256": checker.lock_sha256, "tool_sha256": checker.identities(),
        "axioms": dependencies[EXPECTED_THEOREM], "policy": POLICY,
    }
    validate_profile(profile)
    profile_path = output_dir / "profile.json"
    profile_path.write_bytes(canonical(profile) + b"\n")
    preparation = {
        "schema": "research-exchange/pilot-fixture-preparation/v1", "status": "passed",
        "profile_sha256": digest(canonical(profile)),
        "source_sha256": profile["source_sha256"], "axiom_dependencies": dependencies,
        "exports": {label: {"bytes": len(data), "sha256": digest(data)} for label, data in exports.items()},
        "replay": replay_receipts,
        "application_path_adapter_sha256": file_digest(checker.adapter) if checker.adapter else None,
        "scope": "fixed reviewed true propositions; alternate valid proof is not the approved target",
    }
    receipt_path = output_dir / "preparation-receipt.json"
    receipt_path.write_bytes(canonical(preparation) + b"\n")
    return {"profile": profile, "profile_path": str(profile_path),
            "expected_path": str(output_dir / "expected.export"),
            "alternate_path": str(output_dir / "alternate.export"),
            "preparation_receipt_path": str(receipt_path)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--lean-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--application-path-adapter", type=Path)
    args = parser.parse_args()
    result = prepare_fixture(args.package_root, args.lean_root, args.output_dir, args.application_path_adapter)
    print(json.dumps({key: value for key, value in result.items() if key != "profile"}, sort_keys=True))
    print("ADAPTER_FIXTURE_PREPARED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
