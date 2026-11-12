#!/usr/bin/env python3
"""Cold source-bound Lean bridge audit, dual replay and adversarial controls.

The full integration verifier owns approval of the new bridge source inventory.
This lane refuses any change to the previously reviewed core, fixes every proof
name and statement contract, and builds isolated copies from inspected bytes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time

_CACHE = tempfile.TemporaryDirectory(prefix="bridge-proof-python-")
sys.pycache_prefix = _CACHE.name
sys.dont_write_bytecode = True

CORE_DIGEST = "e46f8f6c12f790d6889085d072b58f92067004077a8b7f430abcb8433bbb0776"
ALLOWED_AXIOMS = {"propext", "Classical.choice", "Quot.sound"}
EXCLUDED = {".git", ".lake", "__pycache__", "evidence", "dist", "node_modules"}
EXPECTED_TARGETS = (
    'ResearchExchangeBridge.Encoding.bytes_injective',
    'ResearchExchangeBridge.Encoding.text_injective',
    'ResearchExchangeBridge.Encoding.digits_injective',
    'ResearchExchangeBridge.Encoding.unframe_field',
    'ResearchExchangeBridge.Encoding.unframe_frame',
    'ResearchExchangeBridge.Encoding.map_bytes_injective',
    'ResearchExchangeBridge.Encoding.frame_injective',
    'ResearchExchangeBridge.Encoding.fields_injective',
    'ResearchExchangeBridge.sourceFields_injective',
    'ResearchExchangeBridge.projectBinding_injective',
    'ResearchExchangeBridge.projectCandidate_injective',
    'ResearchExchangeBridge.ready_implies_core_eligible',
    'ResearchExchangeBridge.ready_implies_core_rejectable',
    'ResearchExchangeBridge.accepted_refines_closure',
    'ResearchExchangeBridge.rejected_refines_closure',
    'ResearchExchangeBridge.inconclusive_is_inert',
    'ResearchExchangeBridge.refusal_is_inert',
    'ResearchExchangeBridge.step_refines_closure',
    'ResearchExchangeBridge.receipt_binding_immutable',
    'ResearchExchangeBridge.authority_snapshot_unchanged',
    'ResearchExchangeBridge.conservation',
    'ResearchExchangeBridge.version_monotone',
    'ResearchExchangeBridge.at_most_one_payout',
    'ResearchExchangeBridge.terminal_is_inert',
    'ResearchExchangeBridge.accepted_effect',
    'ResearchExchangeBridge.rejected_effect',
    'ResearchExchangeBridge.retry_is_inert',
    'ResearchExchangeBridge.wrong_source_refused',
    'ResearchExchangeBridge.substituted_receipt_refused',
    'ResearchExchangeBridge.unauthenticated_refused',
    'ResearchExchangeBridge.wrong_verifier_refused',
    'ResearchExchangeBridge.wrong_requester_refused',
    'ResearchExchangeBridge.revoked_requester_refused',
    'ResearchExchangeBridge.stale_requester_epoch_refused',
    'ResearchExchangeBridge.revoked_verifier_refused',
    'ResearchExchangeBridge.stale_authority_epoch_refused',
    'ResearchExchangeBridge.unchecked_refused',
    'ResearchExchangeBridge.wrong_profile_refused',
    'ResearchExchangeBridge.stale_version_refused',
    'ResearchExchangeBridge.wrong_escrow_refused',
)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def file_sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for data in iter(lambda: f.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def inventory(root):
    out = []
    for p in sorted(root.rglob("*")):
        relative = p.relative_to(root)
        if any(part in EXCLUDED for part in relative.parts):
            continue
        if p.is_symlink():
            raise ValueError("source symlink refused: " + str(relative))
        if p.is_file():
            out.append({"path": relative.as_posix(), "bytes": p.stat().st_size, "sha256": file_sha(p)})
    return out


def check_core(core):
    manifest_file = core / "SOURCE_MANIFEST.json"
    if file_sha(manifest_file) != CORE_DIGEST:
        raise ValueError("frozen core manifest identity changed")
    raw = manifest_file.read_bytes()
    manifest = json.loads(raw)
    if raw != canonical(manifest) or manifest.get("schema") != "formal-research-exchange/source-snapshot/v1":
        raise ValueError("frozen core manifest format changed")
    actual = [p for p in inventory(core) if p["path"] != "SOURCE_MANIFEST.json"]
    if actual != manifest["files"]:
        raise ValueError("frozen core source differs from reviewed inventory")
    return manifest


def check_registry(registry):
    if set(registry) != {"schema", "module", "theorems"} or registry.get("schema") != "research-exchange-bridge/proof-targets/v1":
        raise ValueError("unsupported proof registry")
    if registry.get("module") != "ResearchExchangeBridge" or registry.get("theorems") != list(EXPECTED_TARGETS):
        raise ValueError("fixed proof target registry differs")


def parse_axioms(output, targets, allowed=ALLOWED_AXIOMS):
    found = {}
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    for m in re.finditer(pattern, output):
        name = m.group(1)
        if name in found:
            raise ValueError("duplicate axiom audit target: " + name)
        deps = [] if m.group(2) is None else [x.strip() for x in m.group(2).split(",") if x.strip()]
        forbidden = set(deps) - allowed
        if forbidden:
            raise ValueError("unapproved axioms: " + ",".join(sorted(forbidden)))
        found[name] = deps
    if set(found) != set(targets):
        raise ValueError("incomplete or substituted axiom audit")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    formal = package / "formal/lean"
    core = package.parent / "research_exchange"
    output = args.output_dir.resolve()
    if output.is_relative_to(formal) or output.is_relative_to(core):
        raise ValueError("evidence must be outside proof sources")
    if output.exists() and any(output.iterdir()):
        raise ValueError("refusing to overwrite existing evidence")
    output.mkdir(parents=True, exist_ok=True)
    receipt_path = output / "receipt.json"
    receipt = {"schema": "research-exchange-bridge/lean-receipt/v1", "status": "running", "stages": [],
               "core_source_sha256": CORE_DIGEST, "runner_sha256": file_sha(Path(__file__)), "theorem_count": len(EXPECTED_TARGETS),
               "theorems": list(EXPECTED_TARGETS), "claims": "guarded row forward refinement and lossless binding projection; not Python/SQLite/cryptography/checker-truth verification"}

    def save():
        receipt_path.write_bytes(canonical(receipt))

    def run(label, command, cwd, env, *, expect="success", marker=None, timeout=240):
        started = time.monotonic()
        log = output / (label + ".log")
        print("RUN " + label, flush=True)
        with log.open("wb") as stream:
            process = subprocess.Popen([str(x) for x in command], cwd=cwd, env=env,
                stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                exit_code, timed_out = process.wait(timeout=timeout), False
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                exit_code, timed_out = process.wait(), True
        text = log.read_text(errors="replace")
        passed = not timed_out and ((exit_code == 0) if expect == "success" else (exit_code is not None and exit_code != 0))
        if marker is not None:
            passed = passed and bool(re.search(marker, text, re.MULTILINE | re.DOTALL))
        stage = {"id": label, "command": [str(x) for x in command], "cwd": str(cwd), "exit_code": exit_code,
                 "timed_out": timed_out, "elapsed_seconds": round(time.monotonic()-started, 4),
                 "status": "passed" if passed else "failed", "expect": expect,
                 "log": log.name, "log_sha256": file_sha(log)}
        receipt["stages"].append(stage)
        save()
        if not passed:
            raise ValueError("required stage failed: " + label)
        print("PASSED " + label, flush=True)
        return text

    try:
        check_core(core)
        source_before = inventory(formal)
        receipt["formal_source_inventory"] = source_before
        receipt["formal_source_sha256"] = hashlib.sha256(canonical(source_before)).hexdigest()
        registry = json.loads((formal / "proof_targets.json").read_text())
        check_registry(registry)
        controls = []
        for label, changed in [("omitted_registry_target", {**registry, "theorems": registry["theorems"][:-1]}),
                               ("substituted_registry_target", {**registry, "theorems": [*registry["theorems"][:-1], registry["theorems"][0]]})]:
            try:
                check_registry(changed)
            except ValueError as e:
                controls.append({"id": label, "status": "expected_refusal", "reason": str(e)})
            else:
                raise ValueError("registry negative control unexpectedly passed")
        # Execute only the source-hash-checked helper from the immutable core.
        sys.path.insert(0, str(core / "tools"))
        from runtime_identity import tree_identity
        lean_root = args.lean_root.resolve()
        lock = json.loads((core / "toolchains.lock.json").read_text())
        tool_paths = {name: lean_root / "bin" / name for name in ["lean", "lake", "leanchecker", "leanexport", "lean4lean"]}
        tool_paths["leanshared"] = lean_root / "lib/lean/libleanshared.so"
        identities = {name: file_sha(path) for name, path in tool_paths.items()}
        if any(sha != lock["file_sha256"][name] for name, sha in identities.items()):
            raise ValueError("Lean runtime executable differs from frozen lock")
        lean_tree = tree_identity(lean_root)
        if lean_tree["sha256"] != lock["tree_sha256"]["lean"]:
            raise ValueError("Lean distribution differs from frozen lock")
        receipt["runtime_identity"] = identities
        receipt["runtime_distribution"] = lean_tree
        save()

        work = output / "work"
        core_copy = work / "research_exchange"
        copied_formal = work / "research_exchange_bridge/formal/lean"
        for root, target, entries in [(core, core_copy, inventory(core)), (formal, copied_formal, source_before)]:
            for entry in entries:
                source = root / entry["path"]
                dest = target / entry["path"]
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, dest)
        check_core(core_copy)
        if inventory(copied_formal) != source_before:
            raise ValueError("cold formal copy differs from inspected source")
        env = dict(os.environ)
        env.pop("LD_PRELOAD", None)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONPYCACHEPREFIX"] = _CACHE.name
        env["LEAN_SYSROOT"] = str(lean_root)
        env["PATH"] = str(lean_root / "bin") + os.pathsep + env.get("PATH", "")
        libraries = [copied_formal / ".lake/build/lib/lean", core_copy / "formal/lean/.lake/build/lib/lean"]
        env["LEAN_PATH"] = os.pathsep.join(map(str, libraries))
        run("cold_build_and_fixed_statement_contracts", [tool_paths["lake"], "build"], copied_formal, env,
            marker="Build completed successfully", timeout=300)
        audit = copied_formal / "ProofAudit.lean"
        audit.write_text("import ResearchExchangeBridge\n" + "\n".join("#print axioms " + t for t in EXPECTED_TARGETS) + "\n")
        audit_text = run("axiom_audit", [tool_paths["lean"], audit], copied_formal, env)
        deps = parse_axioms(audit_text, EXPECTED_TARGETS)
        (output / "axioms.json").write_bytes(canonical({"status": "passed", "allowed_axioms": sorted(ALLOWED_AXIOMS), "dependencies": deps}))
        run("proof_export", [tool_paths["leanexport"], "ResearchExchangeBridge", "--", *EXPECTED_TARGETS], copied_formal, env)
        export_path = output / "proofs.export"
        shutil.copyfile(output / "proof_export.log", export_path)
        if not export_path.stat().st_size:
            raise ValueError("empty proof export")
        run("kernel_replay", [tool_paths["leanchecker"], "--from-export", export_path], copied_formal, env,
            marker="Lean default kernel accepts the solution")
        independent = run("independent_replay", [tool_paths["lean4lean"], "--import", export_path], copied_formal, env,
            marker=r"checked [1-9][0-9]* declarations")
        receipt["exported_declarations"] = int(re.search(r"checked ([1-9][0-9]*) declarations", independent).group(1))
        receipt["proof_export_sha256"] = file_sha(export_path)

        for name in ["InconclusivePays.lean", "StaleVersionCommits.lean", "SubstitutedReceiptCommits.lean"]:
            run("refuse_" + Path(name).stem, [tool_paths["lean"], copied_formal / "negative" / name], copied_formal, env,
                expect="refusal", marker="unsolved goals")
            controls.append({"id": name, "status": "expected_refusal"})
        negative_modules = output / "negative_modules"
        negative_modules.mkdir()
        negative_env = dict(env)
        negative_env["LEAN_PATH"] = str(negative_modules) + os.pathsep + env["LEAN_PATH"]
        for module, target, forbidden in [("UnsafeAxiom", "ResearchExchangeBridge.Negative.forgedAxiom", "ResearchExchangeBridge.Negative.attackerAuthority"),
                                          ("SorryExport", "ResearchExchangeBridge.Negative.forgedSorry", "sorryAx")]:
            observed = run("compile_" + module, [tool_paths["lean"], "-o", negative_modules / (module + ".olean"), module + ".lean"],
                           copied_formal / "negative", negative_env, marker=re.escape(forbidden))
            run("export_" + module, [tool_paths["leanexport"], module, "--", target], copied_formal, negative_env)
            try:
                parse_axioms(observed, [target])
            except ValueError as e:
                if forbidden not in str(e):
                    raise
                controls.append({"id": module + "_export_policy", "status": "expected_refusal", "reason": str(e)})
            else:
                raise ValueError("forbidden axiom export passed policy")

        mutant = output / "weakened_contract"
        # Lean selects a namespace directory as a unit. Preserve the unchanged
        # cold-built sibling modules before replacing only this target module.
        shutil.copytree(libraries[0], mutant, dirs_exist_ok=True)
        mutant_module = mutant / "ResearchExchangeBridge/Refinement.lean"
        mutant_module.parent.mkdir(parents=True, exist_ok=True)
        original = (copied_formal / "ResearchExchangeBridge/Refinement.lean").read_text()
        start = original.index("theorem conservation (")
        end = original.index("\ntheorem version_monotone", start)
        weakened = "theorem conservation (cfg : Config) (s : Row) (who : Identity) (p : Prepared)\n    (v : Verdict) : True := by trivial\n"
        mutant_module.write_text(original[:start] + weakened + original[end:])
        mutant_env = dict(env)
        mutant_env["LEAN_PATH"] = str(mutant) + os.pathsep + env["LEAN_PATH"]
        run("compile_weakened_proposition", [tool_paths["lean"], "-o", mutant_module.with_suffix(".olean"), "ResearchExchangeBridge/Refinement.lean"], mutant, mutant_env)
        contract_text = run("refuse_weakened_statement_contract", [tool_paths["lean"], copied_formal / "ResearchExchangeBridge/Contracts.lean"],
                            copied_formal, mutant_env, expect="refusal", marker=r"[Tt]ype mismatch")
        if "conservation" not in contract_text or "True" not in contract_text:
            raise ValueError("statement mutant failed for an unrelated reason")
        controls.append({"id": "weakened_conservation_statement", "status": "expected_refusal"})
        if inventory(formal) != source_before:
            raise ValueError("formal source changed during verification")
        if file_sha(Path(__file__)) != receipt["runner_sha256"]:
            raise ValueError("proof runner changed during verification")
        check_core(core)
        if tree_identity(lean_root)["sha256"] != lean_tree["sha256"]:
            raise ValueError("Lean runtime changed during verification")
        receipt["negative_controls"] = controls
        receipt["negative_control_count"] = len(controls)
        receipt["executable"] = str(copied_formal / ".lake/build/bin/bridge_trace")
        receipt["executable_sha256"] = file_sha(receipt["executable"])
        receipt["status"] = "passed"
        save()
        print("BRIDGE_PROOFS_PASSED " + str(len(EXPECTED_TARGETS)) + " fixed theorems; " + str(len(controls)) + " intended negative controls", flush=True)
        return 0
    except Exception as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
        save()
        print("BRIDGE_PROOFS_FAILED " + str(error), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
