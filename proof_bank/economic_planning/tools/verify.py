#!/usr/bin/env python3
"""Verify the inert planning kernel and retain an exact-source, unsigned receipt.

The receipt distinguishes Lean proofs, executable examples and complete finite
Quint exploration. It does not certify input truth or predictive accuracy.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True
PACKAGE = Path(__file__).resolve().parents[1]
REPO = PACKAGE.parents[1]
SHARED = REPO / "proof_bank/research_exchange"
LOCK = SHARED / "toolchains.lock.json"
ALLOWED_AXIOMS = {"propext", "Quot.sound", "Classical.choice"}
SOURCE_PATHS = [
    "proof_bank/economic_planning",
    "proof_bank/research_exchange/toolchains.lock.json",
    "proof_bank/research_exchange/tooling/quint/package.json",
    "proof_bank/research_exchange/tooling/quint/package-lock.json",
    "proof_bank/research_exchange/tools/bootstrap.py",
    "proof_bank/research_exchange/tools/runtime_identity.py",
    "proof_bank/research_exchange/tools/source_snapshot.py",
    ".github/workflows/economic-planning-verification.yml",
    "docs/architecture/2026-11-11-economic-planning-verification.md",
    "docs/plans/2026-11-11-dispatch-spatial-workspace.md",
]


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


def unique_names(values: object, label: str) -> list[str]:
    if not isinstance(values, list) or not values or any(
        not isinstance(v, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*", v)
        for v in values
    ) or len(set(values)) != len(values):
        raise ValueError(f"{label}: require nonempty, unique, safe identifiers")
    return values


def parse_axioms(log: str, targets: list[str]) -> dict[str, list[str]]:
    unique_names(targets, "axiom audit targets")
    found: dict[str, list[str]] = {}
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    for match in re.finditer(pattern, log):
        name = match[1]
        if name in found:
            raise ValueError(f"duplicate axiom audit: {name}")
        axioms = [a.strip() for a in (match[2] or "").split(",") if a.strip()]
        if set(axioms) - ALLOWED_AXIOMS:
            raise ValueError(f"unapproved axioms: {name}: {axioms}")
        found[name] = axioms
    if set(found) != set(targets):
        raise ValueError("axiom audit does not cover the exact declared inventory")
    return found


def parse_declaration_audit(log: str, targets: list[str]) -> dict:
    unique_names(targets, "declared theorem inventory")
    declarations = re.findall(r"(?m)^DECL (\S+) (theorem|generated|declaration|axiom)$", log)
    closures = re.findall(r"(?m)^AXIOMS (\S+) \[([^\]]*)\]$", log)
    names = [name for name, _ in declarations]
    if not names or len(names) != len(set(names)):
        raise ValueError("missing or duplicate namespace declarations")
    if len(closures) != len(declarations) or {name for name, _ in closures} != set(names) or len({name for name, _ in closures}) != len(closures):
        raise ValueError("namespace axiom closures do not match declarations")
    if any(not name.startswith("EconomicPlanning.") for name in names):
        raise ValueError("declaration outside expected namespace")
    theorems = [name for name, kind in declarations if kind == "theorem"]
    if set(theorems) != set(targets):
        raise ValueError("theorem inventory mismatch")
    declared_counts = re.findall(r"(?m)^AUDIT_DECLARATIONS (\d+)$", log)
    theorem_counts = re.findall(r"(?m)^AUDIT_THEOREMS (\d+)$", log)
    if declared_counts != [str(len(declarations))] or theorem_counts != [str(len(theorems))]:
        raise ValueError("audit totals do not match the complete inventory")
    dependencies = {}
    for name, csv in closures:
        values = [part.strip() for part in csv.split(",") if part.strip()]
        if set(values) - ALLOWED_AXIOMS:
            raise ValueError(f"unapproved axioms: {name}: {values}")
        dependencies[name] = values
    if any(kind == "axiom" for _, kind in declarations):
        raise ValueError("custom namespace axiom")
    return {"declaration_count": len(declarations), "theorem_count": len(theorems),
            "dependencies": dependencies}


def model_result(log: str, code: int, version: str, negative: bool) -> dict:
    if f"# APALACHE version: {version} |" not in log:
        raise ValueError("missing pinned translator identity")
    failures = ["RUNNER_TIMEOUT", "Deadlock reached", "Parsing or semantic analysis failed",
                "unexpected exception", "OutOfMemoryError", "No initial states generated",
                "Failed to translate", "not a state predicate", "EADDRINUSE", "ECONNREFUSED"]
    if any(marker.lower() in log.lower() for marker in failures):
        raise ValueError("execution failure is not a model-check result")
    if negative:
        required = ["Error: Invariant q_inv is violated.",
                    "Error: The behavior up to this point is:",
                    "[violation] Found an issue"]
        if code != 1 or not all(marker in log for marker in required):
            raise ValueError("missing expected invariant counterexample")
        if len(re.findall(r"State\s+\d+:", log)) < 2 or not re.search(
            r"(?m)^\s*(?:/\\\s*)?[A-Za-z_]\w*\s*=\s*\S", log
        ):
            raise ValueError("counterexample contains no state trace")
        return {"result": "expected_invariant_counterexample"}
    stats = re.search(r"(\d+) states generated, (\d+) distinct states found, 0 states left on queue\.", log)
    depth = re.search(r"The depth of the complete state graph search is (\d+)\.", log)
    if code != 0 or not stats or not depth or "Model checking completed. No error has been found." not in log or "Error:" in log or "[violation]" in log:
        raise ValueError("safe model did not complete its finite state graph")
    if not (int(stats[1]) >= int(stats[2]) > 0 and int(depth[1]) > 0):
        raise ValueError("invalid finite exploration counts")
    return {"result": "complete_finite_graph", "generated": int(stats[1]),
            "distinct": int(stats[2]), "queued": 0, "depth": int(depth[1])}


def inventory() -> dict[str, str]:
    paths = git("ls-files", "--", *SOURCE_PATHS).splitlines()
    for required in SOURCE_PATHS:
        if not any(p == required or p.startswith(required + "/") for p in paths):
            raise ValueError(f"required source is not tracked: {required}")
    result = {}
    for name in paths:
        path = REPO / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(REPO):
            raise ValueError(f"source must be a regular in-repository file: {name}")
        actual = sha(path)
        try:
            committed = subprocess.check_output(["git", "-C", str(REPO), "show", f"HEAD:{name}"], stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as exc:
            raise ValueError(f"source is not committed at HEAD: {name}") from exc
        if actual != hashlib.sha256(committed).hexdigest():
            raise ValueError(f"source bytes differ from HEAD: {name}")
        result[name] = actual
    return result


def tools_identity(root: Path, lock: dict) -> dict:
    # Reuse the existing distribution hasher and lock, including all Lean and
    # Quint dependency bytes. A version string alone is insufficient.
    sys.path.insert(0, str(SHARED / "tools"))
    try:
        spec = importlib.util.spec_from_file_location("planning_runtime_identity", SHARED / "tools/runtime_identity.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        directories = {
            "lean": root / lock["downloads"]["lean"]["installed_relative"],
            "jre": root / lock["downloads"]["jre"]["installed_relative"],
            "quint_node_modules": root / "quint/node_modules",
        }
        trees = {name: module.tree_identity(path) for name, path in directories.items()}
    finally:
        sys.path.pop(0)
    for name, data in trees.items():
        if data["sha256"] != lock["tree_sha256"][name]:
            raise ValueError(f"tool distribution mismatch: {name}")
    files = {
        "lean": directories["lean"] / "bin/lean",
        "leanchecker": directories["lean"] / "bin/leanchecker",
        "quint_cli": directories["quint_node_modules"] / "@informalsystems/quint/dist/src/cli.js",
        "java": directories["jre"] / "bin/java",
        "apalache_jar": root / f"quint-home/apalache-dist-{lock['versions']['apalache']}/apalache/lib/apalache.jar",
        "node": Path(shutil.which("node") or "missing-node").resolve(strict=True),
        "python": Path(sys.executable).resolve(strict=True),
    }
    identities = {name: {"path": str(path), "sha256": sha(path)} for name, path in files.items()}
    for name, item in identities.items():
        if name in lock["file_sha256"] and item["sha256"] != lock["file_sha256"][name]:
            raise ValueError(f"tool executable mismatch: {name}")
    return {"trees": trees, "files": identities}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_head) or git("rev-parse", "HEAD") != args.expected_head:
        parser.error("expected-head must be the full current Git commit")
    if git("status", "--porcelain", "--untracked-files=all"):
        parser.error("commit all reviewed source before producing an exact-source receipt")
    output = args.output.resolve()
    if output == REPO or output.is_relative_to(REPO):
        parser.error("write generated evidence outside the repository")
    output.mkdir(parents=True, exist_ok=False)
    build = output / "lean"
    build.mkdir()
    receipt = {
        "schema": "biz-kit/economic-planning/verification-v1",
        "status": "running", "revision": args.expected_head,
        "tree": git("rev-parse", "HEAD^{tree}"),
        "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source_sha256": inventory(), "checks": {},
        "claims": {
            "input_truth_authenticated": False, "forecast_accuracy_verified": False,
            "runtime_refinement_verified": False, "deployed": False,
            "lean_quint_refinement_proved": False,
        },
    }

    def save():
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    def run(name, argv, env, cwd=output, timeout=180):
        start = time.monotonic()
        with subprocess.Popen(list(map(str, argv)), cwd=cwd, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, start_new_session=True, text=True) as proc:
            try:
                log, _ = proc.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                log, _ = proc.communicate()
                log += "\nRUNNER_TIMEOUT\n"
        path = output / f"{name}.log"
        path.write_text(log)
        return {"argv": list(map(str, argv)), "cwd": str(cwd), "exit_code": proc.returncode,
                "seconds": round(time.monotonic() - start, 3), "log": path.name,
                "log_sha256": sha(path)}, log

    def require(name, entry, ok, evidence_class, detail=None):
        entry.update(passed=bool(ok), evidence_class=evidence_class)
        if detail is not None:
            entry["detail"] = detail
        receipt["checks"][name] = entry
        save()
        print(f"{name}: {'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            raise ValueError(f"{name} failed; inspect {entry.get('log', 'receipt.json')}")

    save()
    try:
        lock = json.loads(LOCK.read_text())
        root = args.toolchain.resolve(strict=True)
        receipt["tools"] = tools_identity(root, lock)
        receipt["tool_versions"] = lock["versions"]
        save()
        paths = {name: Path(item["path"]) for name, item in receipt["tools"]["files"].items()}
        env = dict(os.environ)
        for name in ["LD_PRELOAD", "LEAN_PATH", "LEAN_SRC_PATH", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "NODE_OPTIONS"]:
            env.pop(name, None)
        lean_env = dict(env, LEAN_PATH=str(build),
                        PATH=str(paths["lean"].parent) + os.pathsep + env["PATH"])
        quint_env = dict(env, QUINT_HOME=str(root / "quint-home"),
                         PATH=str(paths["java"].parent) + os.pathsep + env["PATH"])
        versions = [
            ("lean_version", [paths["lean"], "--version"], lock["versions"]["lean_commit"]),
            ("quint_version", [paths["node"], paths["quint_cli"], "--version"], lock["versions"]["quint"]),
            ("java_version", [paths["java"], "-version"], 'version "21.0.13"'),
        ]
        for name, argv, marker in versions:
            entry, log = run(name, argv, env)
            require(name, entry, entry["exit_code"] == 0 and marker in log, "tool identity")

        entry, log = run("verifier_controls", [paths["python"], "-I", PACKAGE / "tools/test_verifier.py"], env)
        require("verifier_controls", entry, entry["exit_code"] == 0 and "VERIFIER_CONTROLS_PASSED" in log,
                "verification harness adversarial controls")
        lean_dir = PACKAGE / "lean"
        registry = json.loads((lean_dir / "proof_targets.json").read_text())
        if registry.get("module") != "Proofs" or registry.get("namespace") != "EconomicPlanning":
            raise ValueError("unexpected theorem module/namespace")
        targets = unique_names(registry["theorems"], "theorem registry")
        for module in ["EconomicPlanning", "Proofs", "Contracts", "Audit"]:
            entry, log = run(f"lean_{module.lower()}", [paths["lean"], "-DwarningAsError=true", "-o", build / f"{module}.olean", f"{module}.lean"], lean_env, lean_dir)
            require(f"lean_{module.lower()}", entry, entry["exit_code"] == 0,
                    "independent proposition contracts" if module == "Contracts" else "Lean kernel acceptance")
            if module == "Audit":
                receipt["axiom_audit"] = parse_declaration_audit(log, targets)
                incomplete_rejected = False
                try:
                    parse_declaration_audit(log, targets[:-1])
                except ValueError:
                    incomplete_rejected = True
                require("incomplete_proof_inventory", {"log": entry["log"]}, incomplete_rejected,
                        "expected incomplete-theorem-inventory rejection")
        # Fresh kernel replay checks the compiled model/proofs instead of merely
        # trusting a successful earlier compiler log.
        for module in ["EconomicPlanning", "Proofs", "Contracts"]:
            entry, log = run(f"kernel_replay_{module.lower()}", [paths["leanchecker"], "--fresh", "--verbose", module], lean_env, lean_dir)
            require(f"kernel_replay_{module.lower()}", entry, entry["exit_code"] == 0,
                    "fresh Lean kernel replay")
        expected_tests = unique_names(json.loads((lean_dir / "regressions.json").read_text())["tests"], "Lean regressions")
        entry, log = run("lean_regressions", [paths["lean"], "-DwarningAsError=true", "--run", "Regression.lean"], lean_env, lean_dir)
        actual = re.findall(r"^PASS ([A-Za-z_][A-Za-z0-9_.]*)$", log, re.M)
        require("lean_regressions", entry, entry["exit_code"] == 0 and actual == expected_tests,
                "executable synthetic Lean scenarios", {"tests": actual})
        # A fresh, deliberately unapproved axiom must be rejected by the same
        # parser used for the real proofs, even when Lean accepts its theorem.
        bad = build / "ForbiddenAxiom.lean"
        bad.write_text("axiom planningUntrusted : False\ntheorem planningBad : False := planningUntrusted\n#print axioms planningBad\n")
        entry, log = run("forbidden_axiom", [paths["lean"], bad], lean_env)
        rejected = False
        try:
            parse_axioms(log, ["planningBad"])
        except ValueError as exc:
            rejected = str(exc).startswith("unapproved axioms:")
        require("forbidden_axiom", entry, entry["exit_code"] == 0 and rejected,
                "expected unapproved-axiom rejection")
        false_proof = build / "FalseProof.lean"
        false_proof.write_text("import EconomicPlanning\nexample : (0 : Nat) = 1 := by decide\n")
        entry, log = run("false_proof", [paths["lean"], false_proof], lean_env)
        require("false_proof", entry, entry["exit_code"] == 1 and "decide" in log and "is false" in log,
                "expected false-proposition rejection")
        placeholder = build / "Placeholder.lean"
        placeholder.write_text("example : False := by sorry\n")
        entry, log = run("placeholder_proof", [paths["lean"], "-DwarningAsError=true", placeholder], lean_env)
        require("placeholder_proof", entry, entry["exit_code"] == 1 and "declaration uses" in log and "sorry" in log,
                "expected anonymous-placeholder rejection")
        # Replace a real, otherwise valid registered theorem with True. Its
        # altered module must compile; the independent expected-type contract
        # must then reject the weaker statement for a type mismatch.
        weakened = output / "weakened-proof"
        weakened.mkdir()
        before = (lean_dir / "Proofs.lean").read_text()
        changed, count = re.subn(
            r"(?ms)^theorem trace_capacity_conservation\b.*?(?=^theorem |^end EconomicPlanning)",
            "theorem trace_capacity_conservation : True := by trivial\n\n", before, count=1)
        if count != 1:
            raise ValueError("cannot identify the deliberate theorem-weakening control")
        (weakened / "Proofs.lean").write_text(changed)
        weakened_env = dict(lean_env, LEAN_PATH=str(weakened) + os.pathsep + str(build))
        entry, log = run("weakened_proof_compiles", [paths["lean"], "-DwarningAsError=true", "-o", weakened / "Proofs.olean", "Proofs.lean"], weakened_env, weakened)
        require("weakened_proof_compiles", entry, entry["exit_code"] == 0,
                "deliberate valid-but-weakened theorem")
        entry, log = run("weakened_contract_refused", [paths["lean"], "-DwarningAsError=true", "Contracts.lean"], weakened_env, lean_dir)
        require("weakened_contract_refused", entry, entry["exit_code"] == 1 and "type mismatch" in log.lower()
                and "trace_capacity_conservation" in log,
                "expected independent proposition-contract rejection")

        checks = json.loads((PACKAGE / "quint/checks.json").read_text())
        if checks["model"] != "planning.qnt":
            raise ValueError("unexpected Quint model path")
        model = PACKAGE / "quint" / checks["model"]
        qtests = unique_names(checks["tests"], "Quint scenarios")
        mutants = checks["mutants"]
        unique_names([m["name"] for m in mutants], "Quint mutants")
        for m in mutants:
            unique_names([m["step"], m["invariant"]], "Quint mutant entry")
        for name, argv in [
            ("quint_types", ["typecheck", model]),
            ("quint_scenarios", ["test", model, "--backend", "typescript", "--seed", "123", "--max-samples", "1"]),
        ]:
            entry, log = run(name, [paths["node"], paths["quint_cli"], *argv], quint_env)
            ok = entry["exit_code"] == 0
            if name == "quint_scenarios":
                ok = ok and f"{len(qtests)} passing" in log and all(n in log for n in qtests)
            require(name, entry, ok, "independent finite Quint checks")

        def check_model(name, transition, invariant, negative):
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            entry, log = run(name, [paths["node"], paths["quint_cli"], "verify", model,
                "--backend", "tlc", "--tlc-config", PACKAGE / "quint/tlc.json",
                "--init", checks["init"], "--step", transition, "--invariant", invariant,
                "--apalache-version", lock["versions"]["apalache"],
                "--server-endpoint", f"localhost:{port}", "--verbosity", "3"], quint_env, timeout=420 if not negative else 120)
            entry.update(transition=transition, invariant=invariant)
            try:
                detail = model_result(log, entry["exit_code"], lock["versions"]["apalache"], negative)
                return name, entry, True, "expected Quint counterexample" if negative else "complete finite Quint exploration", detail
            except ValueError as exc:
                return name, entry, False, "Quint model checking", {"error": str(exc)}

        require(*check_model("quint_safety", checks["step"], checks["invariant"], False))
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(check_model, "mutant_" + m["name"], m["step"], m["invariant"], True) for m in mutants]
            for future in futures:
                require(*future.result())
        if git("rev-parse", "HEAD") != args.expected_head or git("status", "--porcelain", "--untracked-files=all") or inventory() != receipt["source_sha256"]:
            raise ValueError("source changed during verification")
        receipt["status"] = "passed"
        receipt["theorem_count"] = len(targets)
        receipt["lean_scenario_count"] = len(expected_tests)
        receipt["quint_scenario_count"] = len(qtests)
        receipt["quint_mutant_count"] = len(mutants)
        receipt["completed_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        print("ECONOMIC_PLANNING_VERIFICATION_PASSED", flush=True)
        return 0
    except Exception as exc:
        receipt.update(status="failed", error=str(exc))
        raise
    finally:
        save()


if __name__ == "__main__":
    raise SystemExit(main())
