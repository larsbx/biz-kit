#!/usr/bin/env python3
"""Run the complete finite Quint slice; never turn tool errors into passes."""
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quint-cli", type=Path, required=True)
    parser.add_argument("--java-bin", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = args.output_dir.resolve()
    if output == source or source in output.parents:
        parser.error("evidence must be outside formal/quint")
    output.mkdir(parents=True, exist_ok=True)
    cli = args.quint_cli.resolve(strict=True)
    java = args.java_bin.resolve(strict=True)
    node = shutil.which("node")
    if not node:
        parser.error("node is required on PATH")
    home = os.environ.get("QUINT_HOME")
    if not home or not (Path(home) / f"apalache-dist-{APALACHE_VERSION}" / "apalache/lib/apalache.jar").is_file():
        parser.error(f"QUINT_HOME must contain the installed Apalache {APALACHE_VERSION} distribution")
    env = os.environ.copy()
    env["PATH"] = str(java.parent) + os.pathsep + env.get("PATH", "")
    env["QUINT_HOME"] = str(Path(home).resolve())
    # All subprocess working directories and logs are below the evidence directory.
    # A fresh localhost port makes reuse of an unrelated translator unlikely; each
    # verification also requires the requested version's startup banner.
    summary = {
        "schema": "formal-research-exchange/quint-evidence/v1",
        "status": "running",
        "toolchain": {"quint": QUINT_VERSION, "apalache": APALACHE_VERSION,
                      "quint_cli": str(cli), "java_bin": str(java), "node": node},
        "source_sha256": {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (source / "quota.qnt", source / "reward.qnt", source / "tlc.json", Path(__file__).resolve())
        },
        "scope": {
            "reward": "one prefunded unit, participants 1 and 2, clock 0..2, at most two generations, two artifacts, exact binding plus four single-field mismatches",
            "quota": "one reservation, initial balance 3, cap and cost requests 0..4",
            "properties": "safety under atomic interleavings; no fairness or liveness claim",
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
            log, _ = proc.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGKILL)
            log, _ = proc.communicate()
            log += "\nRUNNER_TIMEOUT\n"
        (directory / "output.log").write_text(log)
        entry = {"id": label, "command": argv, "exit_code": proc.returncode,
                 "seconds": round(time.monotonic() - started, 3), "timed_out": timed_out,
                 "log": str((directory / "output.log").relative_to(output))}
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
        require(entry, rc == 0 and log.strip() == QUINT_VERSION, "pinned CLI version")
        rc, log, entry = command("java_version", [str(java), "-version"])
        require(entry, rc == 0 and re.search(r'version "21\.', log) is not None, "Java 21 runtime")
        for model, count in (("quota", 3), ("reward", 4)):
            path = str(source / f"{model}.qnt")
            rc, log, entry = command(f"{model}_typecheck", [node, str(cli), "typecheck", path])
            require(entry, rc == 0, "Quint static type and effect checking")
            rc, log, entry = command(f"{model}_scenarios", [node, str(cli), "test", path,
                "--main", model, "--backend=typescript", "--seed", "123", "--max-samples", "1", "--verbosity", "2"])
            require(entry, rc == 0 and re.search(rf'\b{count} passing\b', log) is not None,
                    "deterministic transition scenarios")

        cases = [
            ("quota_safety", "quota", "step", "safety", False),
            ("reward_safety", "reward", "step", "safety", False),
            ("reject_duplicate_payment", "reward", "duplicatePaymentStep", "singlePayout", True),
            ("reject_wrong_target", "reward", "wrongBindingStep", "exactBinding", True),
            ("reject_stale_lease", "reward", "staleLeaseStep", "freshAdmission", True),
            ("reject_early_refund", "quota", "earlyRefundStep", "noEarlyRefund", True),
        ]
        for label, model, step, invariant, negative in cases:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            argv = [node, str(cli), "verify", str(source / f"{model}.qnt"),
                    "--main", model, "--init", "init", "--step", step, "--invariant", invariant,
                    "--backend=tlc", "--tlc-config", str(source / "tlc.json"),
                    "--apalache-version", APALACHE_VERSION,
                    "--server-endpoint", f"localhost:{port}", "--verbosity=3"]
            rc, log, entry = command(label, argv)
            entry.update({"step": step, "invariant": invariant, "negative_control": negative})
            correct_translator = f"# APALACHE version: {APALACHE_VERSION} |" in log
            if negative:
                # One named invariant per invocation: q_inv is precisely that property.
                # Syntax errors, timeouts, JVM failures and deadlocks do not satisfy this.
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
        print("QUINT_CHECKS_PASSED 2 exhaustive models; 7 scenarios; 4 targeted mutants", flush=True)
        return 0
    except (OSError, RuntimeError) as exc:
        summary["status"] = "failed"
        summary["error"] = str(exc)
        save()
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
