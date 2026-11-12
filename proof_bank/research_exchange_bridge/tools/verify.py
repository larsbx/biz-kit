#!/usr/bin/env python3
"""Require the complete bridge proof/model/runtime profile at one source revision."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
sys.path.insert(0, str(ROOT.parent))
from research_exchange_bridge.common import canonical, core_identity, loads, sha

SOURCE_PATHS = ["proof_bank/research_exchange", "proof_bank/research_exchange_mcp",
                "proof_bank/research_exchange_bridge", "docs/proof-bank/research-exchange",
                ".github/workflows/proof-bank-research-exchange.yml",
                ".github/workflows/research-exchange-adapter.yml",
                ".github/workflows/research-exchange-durable-bridge.yml"]
EXCLUDE = {".lake", "__pycache__", "evidence", "dist", "node_modules"}
REQUIRED = ("proofs", "models", "reviewed_profile", "runtime_acceptance",
            "source_acceptance", "representation_conformance")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=REPO, text=True).strip()


def source_snapshot():
    files = []
    for name in SOURCE_PATHS:
        root = REPO / name
        if not root.exists():
            raise ValueError("Missing required source: " + name)
        paths = sorted(root.rglob("*")) if root.is_dir() else [root]
        for path in paths:
            relative = path.relative_to(REPO)
            if any(part in EXCLUDE for part in relative.parts):
                continue
            if path.is_symlink():
                raise ValueError("Source symlink refused: " + str(relative))
            if path.is_file():
                data = path.read_bytes()
                files.append({"path": relative.as_posix(), "bytes": len(data), "sha256": sha(data)})
    return {"files": sorted(files, key=lambda item: item["path"])}


def acceptance_passed(stages):
    return ([stage.get("id") for stage in stages] == list(REQUIRED) and
            all(stage.get("status") == "passed" and stage.get("exit_code") == 0 for stage in stages))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-root", required=True, type=Path)
    parser.add_argument("--quint-cli", required=True, type=Path)
    parser.add_argument("--java-bin", required=True, type=Path)
    parser.add_argument("--quint-home", required=True, type=Path)
    parser.add_argument("--elixir", required=True, type=Path)
    parser.add_argument("--source-imports", required=True, type=Path,
                        help="Operator-built compiled imports for the pinned bounded Lean source profile")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--expected-revision")
    parser.add_argument("--allow-dirty", action="store_true", help="Local development only; recorded as uncommitted evidence")
    args = parser.parse_args()
    for name in ("lean_root", "quint_cli", "java_bin", "quint_home", "elixir", "source_imports"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit("A new or empty evidence directory is required")
    output.mkdir(parents=True, exist_ok=True)
    stages = []
    receipt = {"schema": "research-exchange/durable-bridge-verification/v1", "status": "failed",
               "required_stage_ids": list(REQUIRED), "stages": stages,
               "started_at": datetime.now(timezone.utc).isoformat(),
               "scope": "reviewed-export and bounded-lean-source-v1 local SQLite/MCP profiles; no general source execution, public service or credit issuance"}
    before = None
    try:
        head = git("rev-parse", "HEAD")
        if args.expected_revision and head != args.expected_revision:
            raise ValueError("Checked-out revision differs from required integration head")
        dirty = bool(git("status", "--porcelain=v1", "--untracked-files=all", "--", *SOURCE_PATHS))
        if dirty and not args.allow_dirty:
            raise ValueError("Exchange sources must match the checked-out Git commit")
        before = source_snapshot()
        receipt.update(git_commit=head, git_tree=git("rev-parse", "HEAD^{tree}"),
                       source_matches_commit=not dirty, reviewed_core=core_identity(),
                       source_sha256=sha(canonical(before)), source_files=len(before["files"]))
        (output / "source-before.json").write_bytes(canonical(before) + b"\n")
        proof_output = output / "proofs"
        acceptance_output = output / "runtime"
        source_output = output / "source"
        fixtures = output / "fixtures"
        commands = [
            ("proofs", [sys.executable, "-B", str(ROOT / "tools/check_bridge_proofs.py"),
                        "--lean-root", str(args.lean_root), "--output-dir", str(proof_output)]),
            ("models", [sys.executable, "-B", str(ROOT / "tools/run_model_checks.py"),
                        "--quint-cli", str(args.quint_cli), "--java-bin", str(args.java_bin),
                        "--quint-home", str(args.quint_home), "--output-dir", str(output / "models")]),
            ("reviewed_profile", [sys.executable, "-B", "-m", "adapter_pilot.prepare_fixture",
                                  "--lean-root", str(args.lean_root), "--output-dir", str(fixtures)]),
            ("runtime_acceptance", [sys.executable, "-B", str(ROOT / "tools/run_acceptance.py"),
                                    "--lean-root", str(args.lean_root), "--fixtures", str(fixtures),
                                    "--elixir", str(args.elixir), "--output-dir", str(acceptance_output)]),
            ("source_acceptance", [sys.executable, "-B", str(ROOT / "tools/run_source_acceptance.py"),
                                   "--lean-root", str(args.lean_root), "--source-imports", str(args.source_imports),
                                   "--elixir", str(args.elixir), "--output-dir", str(source_output)]),
            ("representation_conformance", [sys.executable, "-B", str(ROOT / "tools/run_conformance.py"),
                                             "--acceptance-evidence", str(acceptance_output),
                                             "--acceptance-evidence", str(source_output),
                                             "--output-dir", str(output / "conformance")]),
        ]
        for identity, command in commands:
            if identity == "representation_conformance":
                # Proof-run timing observations may contain decimal durations;
                # they are evidence metadata, not the integer-only MCP protocol.
                proof_summary = json.loads((proof_output / "receipt.json").read_bytes())
                if proof_summary.get("status") != "passed":
                    raise ValueError("The complete cold proof receipt must pass")
                executable = proof_summary.get("bridge_trace") or proof_summary.get("executable")
                if not executable:
                    raise ValueError("Cold proof run must identify its compiled bridge_trace executable")
                executable_digest = proof_summary.get("executable_sha256")
                if not executable_digest or sha(Path(executable).read_bytes()) != executable_digest:
                    raise ValueError("Compiled representation executable differs from cold proof evidence")
                command += ["--lean-command", str(executable), "--expected-lean-sha256", executable_digest]
            start = time.monotonic_ns()
            log = output / (identity + ".log")
            cwd = ROOT.parent / "research_exchange" if identity == "reviewed_profile" else REPO
            try:
                with log.open("wb") as stream:
                    run = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                         timeout=1200, check=False)
                code = run.returncode
            except subprocess.TimeoutExpired:
                code = -1
            stage = {"id": identity, "command": command, "exit_code": code,
                     "elapsed_ns": time.monotonic_ns() - start,
                     "status": "passed" if code == 0 else "failed", "log": log.name,
                     "log_sha256": sha(log.read_bytes())}
            stages.append(stage)
            print(identity + ": " + stage["status"], flush=True)
            if code != 0:
                raise ValueError("Required stage failed: " + identity)
        if source_snapshot() != before:
            raise ValueError("Reviewed sources changed during execution")
        if not acceptance_passed(stages):
            raise ValueError("Every required stage must pass in order")
        receipt["status"] = "passed"
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
        print("BRIDGE_VERIFICATION_REFUSED: " + str(error), file=sys.stderr)
    finally:
        receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
        receipt["stages_not_run"] = [stage for stage in REQUIRED if stage not in [x["id"] for x in stages]]
        if before is not None:
            try:
                after = source_snapshot()
                (output / "source-after.json").write_bytes(canonical(after) + b"\n")
                receipt["source_unchanged"] = after == before
                if after != before:
                    receipt.update(status="failed", error="Reviewed sources changed during execution")
            except (OSError, ValueError) as error:
                receipt.update(status="failed", source_unchanged=False, error=str(error))
        artifacts = []
        for path in sorted(output.rglob("*")):
            relative = path.relative_to(output)
            if any(part in ("work", ".lake", "__pycache__") for part in relative.parts):
                continue
            if path.is_file() and relative.as_posix() != "receipt.json":
                data = path.read_bytes()
                artifacts.append({"path": relative.as_posix(), "bytes": len(data), "sha256": sha(data)})
        receipt["artifacts"] = artifacts
        (output / "receipt.json").write_bytes(canonical(receipt) + b"\n")
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
