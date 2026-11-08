#!/usr/bin/env python3
"""Run the approved verification plan and emit an unsigned, exact-source receipt."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

# Select a fresh cache location before importing any project-local module.
# -B alone does not prevent loading stale timestamp-valid bytecode.
_RUNNER_CACHE = tempfile.TemporaryDirectory(prefix="fre-runner-pycache-")
sys.pycache_prefix = _RUNNER_CACHE.name
sys.dont_write_bytecode = True

from source_snapshot import canonical, verify_manifest
from runtime_identity import file_sha, tree_identity


REQUIRED_STAGE_IDS = (
    "gate_unit_tests", "lean_build", "lean_axioms", "lean_export",
    "lean_kernel_replay", "lean_independent_replay", "lean_negative_controls",
    "reference_unit_tests", "differential_traces", "quint_model_checks",
    "adapter_model_checks", "adapter_acceptance",
)


def validate_plan(plan: dict) -> list[str]:
    """Refuse partial, reordered or non-successful top-level acceptance gates."""
    if not isinstance(plan, dict) or plan.get("schema") != "formal-research-exchange/verification-plan/v1":
        raise ValueError("a supported verification plan is required")
    stages = plan.get("stages")
    if not isinstance(stages, list) or any(not isinstance(stage, dict) for stage in stages):
        raise ValueError("verification stages must be a list of stage objects")
    names = [stage.get("id") for stage in stages]
    if names != list(REQUIRED_STAGE_IDS):
        raise ValueError("the complete ordered 12-stage verification plan is required")
    for stage in stages:
        command = stage.get("command")
        patterns = stage.get("required_patterns")
        timeout = stage.get("timeout_seconds")
        if not isinstance(command, list) or not command or any(
                not isinstance(part, str) or not part for part in command):
            raise ValueError(f"nonempty command required: {stage['id']}")
        if not isinstance(patterns, list) or not patterns or any(
                not isinstance(pattern, str) or not pattern for pattern in patterns):
            raise ValueError(f"positive completion evidence required: {stage['id']}")
        if type(timeout) is not int or timeout <= 0:
            raise ValueError(f"positive timeout required: {stage['id']}")
        # Mutant subprocesses may return failure, but their aggregate runner must
        # itself succeed after verifying the precise expected counterexamples.
        codes = stage.get("expected_exit_codes", [0])
        if (not isinstance(codes, list) or len(codes) != 1 or
                type(codes[0]) is not int or codes[0] != 0):
            raise ValueError(f"top-level stage must require exit code zero: {stage['id']}")
    return names


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def fresh_python_environment(env: dict[str, str], cache: Path) -> dict[str, str]:
    cache.mkdir(parents=True, exist_ok=False)
    result = dict(env)
    result["PYTHONPYCACHEPREFIX"] = str(cache)
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    return result


def call(command: list[str], cwd: Path, env: dict[str, str], timeout: int, log: Path) -> dict:
    started = time.monotonic()
    timed_out = False
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            exit_code = process.wait()
    return {
        "command": command, "cwd": str(cwd), "exit_code": exit_code,
        "timed_out": timed_out, "elapsed_seconds": round(time.monotonic() - started, 4),
        "log": log.name, "log_bytes": log.stat().st_size, "log_sha256": file_sha(log)
    }


def run_stage(stage: dict, root: Path, output: Path, substitutions: dict[str, str],
              env: dict[str, str]) -> dict:
    name = stage["id"]
    if not re.fullmatch(r"[a-z0-9_]+", name):
        raise ValueError("invalid stage id")
    command = [part.format_map(substitutions) for part in stage["command"]]
    cwd = (root / stage.get("cwd", ".")).resolve()
    if not cwd.is_relative_to(root):
        raise ValueError("stage working directory escapes the project")
    stage_env = dict(env)
    for key, value in stage.get("env", {}).items():
        stage_env[key] = value.format_map(substitutions)
    print(f"RUN {name}", flush=True)
    outcome = call(command, cwd, stage_env, stage.get("timeout_seconds", 180), output / f"{name}.log")
    text = (output / outcome["log"]).read_text(errors="replace")
    codes = stage.get("expected_exit_codes", [0])
    outcome["id"] = name
    outcome["evidence_class"] = stage["evidence_class"]
    outcome["expected_exit_codes"] = codes
    outcome["missing_required_patterns"] = [
        pattern for pattern in stage.get("required_patterns", [])
        if not re.search(pattern, text, re.MULTILINE | re.DOTALL)
    ]
    outcome["matched_forbidden_patterns"] = [
        pattern for pattern in stage.get("forbidden_patterns", [])
        if re.search(pattern, text, re.MULTILINE | re.DOTALL)
    ]
    outcome["status"] = "passed" if (
        not outcome["timed_out"] and outcome["exit_code"] in codes
        and not outcome["missing_required_patterns"] and not outcome["matched_forbidden_patterns"]
    ) else "failed"
    print(f"{outcome['status'].upper()} {name} ({outcome['elapsed_seconds']}s)", flush=True)
    return outcome


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-source-sha256", required=True)
    parser.add_argument("--lean-root", type=Path, required=True)
    parser.add_argument("--quint-cli", type=Path, required=True)
    parser.add_argument("--java-bin", type=Path, required=True)
    parser.add_argument("--quint-home", type=Path, required=True)
    parser.add_argument("--app-path-shim", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    # Before starting tools or clearing generated outputs, reject unreviewed source.
    manifest = verify_manifest(root, args.expected_source_sha256)
    plan = json.loads((root / "verification.plan.json").read_text())
    names = validate_plan(plan)

    lean_root = args.lean_root.resolve()
    quint_cli = args.quint_cli.resolve()
    java_bin = args.java_bin.resolve()
    quint_home = args.quint_home.resolve()
    node = shutil.which("node")
    if node is None:
        raise ValueError("node is unavailable")
    for required in [lean_root / "bin/lean", lean_root / "bin/lake", quint_cli, java_bin]:
        if not required.is_file():
            raise ValueError(f"required tool not found: {required}")
    run_id = str(uuid.uuid4())
    output = args.output.resolve() if args.output else root / "evidence" / run_id
    if output.exists() and any(output.iterdir()):
        raise ValueError("refusing to overwrite an existing evidence directory")
    output.mkdir(parents=True, exist_ok=True)
    env = fresh_python_environment(dict(os.environ), output / "python-cache")
    env["PATH"] = os.pathsep.join([str(lean_root / "bin"), str(java_bin.parent), env.get("PATH", "")])
    env["QUINT_HOME"] = str(quint_home)
    env["LEAN_SYSROOT"] = str(lean_root)
    env["LEAN_PATH"] = str(root / "formal/lean/.lake/build/lib/lean")
    env["PYTHONPATH"] = str(root)
    env["FRE_LEAN_ROOT"] = str(lean_root)
    env.pop("FRE_APPLICATION_PATH", None)
    # The acceptance driver must not inherit an unselected application-path
    # adapter. Expose this setting only after the explicit adapter is hash-checked.
    env.pop("FRE_APP_PATH_SHIM", None)
    if args.app_path_shim:
        shim = args.app_path_shim.resolve()
        if not shim.is_file():
            raise ValueError("explicit application-path adapter not found")
        env["LD_PRELOAD"] = str(shim) + (":" + env["LD_PRELOAD"] if env.get("LD_PRELOAD") else "")
    else:
        shim = None
    substitutions = {
        "root": str(root), "output": str(output), "python": sys.executable, "node": node,
        "lean": str(lean_root / "bin/lean"), "lake": str(lean_root / "bin/lake"),
        "leanchecker": str(lean_root / "bin/leanchecker"),
        "leanexport": str(lean_root / "bin/leanexport"),
        "lean4lean": str(lean_root / "bin/lean4lean"), "quint": str(quint_cli),
        "java": str(java_bin), "quint_home": str(quint_home)
    }
    identity_paths = {
        "lean": lean_root / "bin/lean", "lake": lean_root / "bin/lake",
        "leanchecker": lean_root / "bin/leanchecker",
        "leanexport": lean_root / "bin/leanexport",
        "lean4lean": lean_root / "bin/lean4lean",
        "leanshared": lean_root / "lib/lean/libleanshared.so",
        "quint_cli": quint_cli, "java": java_bin,
        "python": Path(sys.executable).resolve(), "node": Path(node).resolve(),
        "apalache_jar": quint_home / "apalache-dist-0.62.4/apalache/lib/apalache.jar"
    }
    if shim:
        identity_paths["application_path_adapter"] = shim
    for name, path in identity_paths.items():
        if not path.is_file():
            raise ValueError(f"required runtime identity missing: {name}")
    identities = {name: {"path": str(path), "sha256": file_sha(path)}
                  for name, path in identity_paths.items()}
    runtime_lock = json.loads((root / "toolchains.lock.json").read_text())
    if runtime_lock.get("schema") != "formal-research-exchange/toolchains/v1":
        raise ValueError("unsupported toolchain lock schema")
    for name, expected in runtime_lock.get("file_sha256", {}).items():
        if identities.get(name, {}).get("sha256") != expected:
            raise ValueError(f"runtime hash mismatch: {name}")
    for name, expected in runtime_lock.get("optional_file_sha256", {}).items():
        if name in identities and identities[name]["sha256"] != expected:
            raise ValueError(f"optional runtime hash mismatch: {name}")
    if shim:
        approved_shim = runtime_lock.get("optional_file_sha256", {}).get("application_path_adapter")
        if not approved_shim or identities["application_path_adapter"]["sha256"] != approved_shim:
            raise ValueError("application-path adapter is not explicitly approved by the runtime lock")
        env["FRE_APP_PATH_SHIM"] = str(shim)
    tree_paths = {"lean": lean_root, "quint_node_modules": quint_cli.parents[4],
                  "jre": java_bin.parent.parent}
    print("Hashing the pinned tool distributions", flush=True)
    trees = {name: tree_identity(path) for name, path in tree_paths.items()}
    for name, expected in runtime_lock["tree_sha256"].items():
        if trees.get(name, {}).get("sha256") != expected:
            raise ValueError(f"runtime distribution hash mismatch: {name}")
    receipt = {
        "schema": "formal-research-exchange/verification-receipt/v1", "run_id": run_id,
        "started_at": utc_now(), "source_sha256": args.expected_source_sha256,
        "source_file_count": len(manifest["files"]), "runtime_identity": identities,
        "runtime_distributions": trees,
        "python_source_policy": "fresh cache prefix; existing project bytecode ignored; cache writes disabled",
        "status": "running", "signature": None,
        "scope": plan["scope"], "assumptions": plan["assumptions"],
        "required_stage_count": len(REQUIRED_STAGE_IDS), "required_stage_ids": names,
        "stages": []
    }
    receipt_path = output / "receipt.json"
    receipt_path.write_bytes(canonical(receipt))
    # Only this project's reproducible build outputs are cleared.
    build = root / "formal/lean/.lake/build"
    if build.exists():
        shutil.rmtree(build)
    failed = False
    try:
        for stage in plan["stages"]:
            verify_manifest(root, args.expected_source_sha256)
            result = run_stage(stage, root, output, substitutions, env)
            receipt["stages"].append(result)
            receipt_path.write_bytes(canonical(receipt))
            if result["status"] != "passed":
                failed = True
                break
        verify_manifest(root, args.expected_source_sha256)
        for name, path in identity_paths.items():
            if file_sha(path) != identities[name]["sha256"]:
                raise ValueError(f"runtime changed during verification: {name}")
        for name, path in tree_paths.items():
            if tree_identity(path) != trees[name]:
                raise ValueError(f"runtime distribution changed during verification: {name}")
    except Exception as exc:
        failed = True
        receipt["error"] = str(exc)
    if ([stage["id"] for stage in receipt["stages"]] != names or
            any(stage["status"] != "passed" for stage in receipt["stages"])):
        failed = True
    receipt["status"] = "failed" if failed else "passed"
    receipt["finished_at"] = utc_now()
    receipt["stages_not_run"] = names[len(receipt["stages"]):]
    receipt["artifacts"] = [
        {"path": path.relative_to(output).as_posix(), "bytes": path.stat().st_size,
         "sha256": file_sha(path)}
        for path in sorted(output.rglob("*"))
        if path.is_file() and not path.is_symlink() and path != receipt_path
    ]
    receipt_path.write_bytes(canonical(receipt))
    print(json.dumps({"status": receipt["status"], "receipt": str(receipt_path),
                      "source_sha256": args.expected_source_sha256}), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, FileNotFoundError, json.JSONDecodeError) as exc:
        print(f"verification refused: {exc}", file=sys.stderr)
        raise SystemExit(2)
