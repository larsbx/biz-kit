#!/usr/bin/env python3
"""Require exhaustive finite adapter safety and genuine TLC mutant counterexamples."""
from __future__ import annotations

import argparse
import hashlib
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

QUINT_VERSION = "0.33.1"
APALACHE_VERSION = "0.62.4"
SCENARIO_COUNT = 10
CASES = (
    ("adapter_safety", "step", "safety", False),
    ("reject_unauthorized_commit", "unauthorizedStep", "authorizedEffects", True),
    ("reject_unchecked_commit", "uncheckedStep", "checkedExactEvidence", True),
    ("reject_wrong_profile", "wrongProfileStep", "checkedExactEvidence", True),
    ("reject_wrong_candidate", "wrongCandidateStep", "exactSettlement", True),
    ("reject_stale_epoch", "staleEpochStep", "currentGrantOnly", True),
    ("reject_revoked_grant", "revokedGrantStep", "currentGrantOnly", True),
    ("reject_stale_version", "staleVersionStep", "currentVersionOnly", True),
    ("reject_split_write", "splitWriteStep", "atomicSettlement", True),
    ("reject_duplicate_payment", "duplicatePaymentStep", "singlePayout", True),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quint-cli", type=Path, required=True)
    parser.add_argument("--java-bin", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = args.output_dir.resolve()
    if output == source or source in output.parents:
        parser.error("evidence must be outside formal/quint")
    if not 1 <= args.timeout_seconds <= 600:
        parser.error("--timeout-seconds must be between 1 and 600")
    output.mkdir(parents=True, exist_ok=True)
    cli = args.quint_cli.resolve(strict=True)
    java = args.java_bin.resolve(strict=True)
    node = shutil.which("node")
    if not node:
        parser.error("node is required on PATH")
    home = os.environ.get("QUINT_HOME")
    if not home or not (Path(home) / f"apalache-dist-{APALACHE_VERSION}" /
                        "apalache/lib/apalache.jar").is_file():
        parser.error(f"QUINT_HOME must contain the installed Apalache {APALACHE_VERSION} distribution")
    env = os.environ.copy()
    env["PATH"] = str(java.parent) + os.pathsep + env.get("PATH", "")
    env["QUINT_HOME"] = str(Path(home).resolve())
    model = source / "adapter.qnt"
    summary = {
        "schema": "formal-research-exchange/adapter-quint-evidence/v1",
        "status": "running",
        "toolchain": {"quint": QUINT_VERSION, "apalache": APALACHE_VERSION,
                      "quint_cli": str(cli), "java_bin": str(java), "node": node},
        "source_sha256": {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (model, source / "tlc.json", Path(__file__).resolve())
        },
        "scope": {
            "domains": "one admitted immutable candidate, two possible worker recipients, one verifier, two prepared request slots, one prefunded credit, row versions 0..2, grant epochs 0..2",
            "attempts": "authenticated workers, anonymous verifier claims, wrong scope, unchecked evidence, wrong profile, and each single-field candidate mismatch",
            "failures": "process death before commit or after atomic state/ledger/receipt commit; response loss and authorized retries",
            "interference": "bounded trusted grant revocation/rotation and version-only DB interference; these are conservative environment actions, not public worker endpoints",
            "properties": "complete finite safety exploration under atomic durable commits; no liveness, fairness, cryptographic authentication, checker correctness, or SQL implementation-refinement theorem",
            "request_identity": "two fixed canonical verification requests; changed-payload request-ID aliasing is a concrete adapter-test obligation outside this model",
        },
        "checks": [],
    }

    def save() -> None:
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    def command(label: str, argv: list[str]) -> tuple[int, str, dict]:
        directory = output / label
        directory.mkdir(exist_ok=True)
        started = time.monotonic()
        proc = subprocess.Popen(argv, cwd=directory, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)
        timed_out = False
        try:
            log, _ = proc.communicate(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGKILL)
            log, _ = proc.communicate()
            log += "\nRUNNER_TIMEOUT\n"
        logfile = directory / "output.log"
        logfile.write_text(log)
        entry = {"id": label, "command": argv, "exit_code": proc.returncode,
                 "seconds": round(time.monotonic() - started, 3), "timed_out": timed_out,
                 "log": str(logfile.relative_to(output)),
                 "log_sha256": hashlib.sha256(logfile.read_bytes()).hexdigest()}
        summary["checks"].append(entry)
        return proc.returncode, log, entry

    def require(entry: dict, passed: bool, classification: str) -> None:
        entry["status"] = "passed" if passed else "failed"
        entry["evidence_class"] = classification
        save()
        print(f'{entry["id"]}: {entry["status"]} ({entry["seconds"]}s)', flush=True)
        if not passed:
            raise RuntimeError(f'{entry["id"]}: required evidence absent; see {output / entry["log"]}')

    try:
        rc, log, entry = command("quint_version", [node, str(cli), "--version"])
        require(entry, rc == 0 and not entry["timed_out"] and log.strip() == QUINT_VERSION,
                "pinned CLI version")
        rc, log, entry = command("java_version", [str(java), "-version"])
        require(entry, rc == 0 and not entry["timed_out"] and re.search(r'version "21\.', log) is not None,
                "Java 21 runtime")
        rc, log, entry = command("adapter_typecheck", [node, str(cli), "typecheck", str(model)])
        require(entry, rc == 0 and not entry["timed_out"], "Quint static type and effect checking")
        rc, log, entry = command("adapter_scenarios", [node, str(cli), "test", str(model),
            "--main", "adapter", "--backend=typescript", "--seed", "123",
            "--max-samples", "1", "--verbosity", "2"])
        require(entry, rc == 0 and not entry["timed_out"] and
                re.search(rf'\b{SCENARIO_COUNT} passing\b', log) is not None,
                "deterministic transition scenarios")
        entry["scenario_count"] = SCENARIO_COUNT
        for label, step, invariant, negative in CASES:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            argv = [node, str(cli), "verify", str(model), "--main", "adapter",
                    "--init", "init", "--step", step, "--invariant", invariant,
                    "--backend=tlc", "--tlc-config", str(source / "tlc.json"),
                    "--apalache-version", APALACHE_VERSION,
                    "--server-endpoint", f"localhost:{port}", "--verbosity=3"]
            rc, log, entry = command(label, argv)
            entry.update({"step": step, "invariant": invariant, "negative_control": negative})
            correct_translator = f"# APALACHE version: {APALACHE_VERSION} |" in log
            if negative:
                # A syntax/type error, failed JVM, deadlock or timeout is NEVER a
                # successful mutant. q_inv names exactly the requested invariant.
                passed = (rc == 1 and correct_translator and not entry["timed_out"] and
                          "Error: Invariant q_inv is violated." in log and
                          "Error: The behavior up to this point is:" in log and
                          "[violation] Found an issue" in log)
                require(entry, passed, "expected counterexample to the named safety invariant")
            else:
                stats = re.search(r'(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue\.', log)
                depth = re.search(r'The depth of the complete state graph search is (\d+)\.', log)
                if stats:
                    entry["states"] = dict(zip(("generated", "distinct", "queued"), map(int, stats.groups())))
                if depth:
                    entry["depth"] = int(depth.group(1))
                passed = (rc == 0 and correct_translator and not entry["timed_out"] and
                          "Model checking completed. No error has been found." in log and
                          stats is not None and int(stats.group(3)) == 0 and depth is not None)
                require(entry, passed, "complete finite reachable-state safety exploration")
        summary["status"] = "passed"
        save()
        print(f"QUINT_ADAPTER_CHECKS_PASSED 1 exhaustive model; {SCENARIO_COUNT} scenarios; {len(CASES) - 1} targeted mutants", flush=True)
        return 0
    except (OSError, RuntimeError) as exc:
        summary["status"] = "failed"
        summary["error"] = str(exc)
        save()
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
