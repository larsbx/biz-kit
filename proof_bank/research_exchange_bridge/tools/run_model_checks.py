#!/usr/bin/env python3
"""Check the independent finite bridge model and genuine invariant-breaking mutants."""
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
JRE_VERSION = "21.0.13+9"
SCENARIO_COUNT = 21
# Each control runs TLC with exactly the named invariant. A crash, parser error,
# timeout, failed JVM, or unrelated invariant failure cannot satisfy a control.
CASES = (
    ("bridge_safety", "step", "safety", False),
    ("reject_split_admission", "splitAdmissionStep", "atomicAdmission", True),
    ("reject_replaced_submission", "replacedSubmissionStep", "immutableAdmission", True),
    ("reject_wrong_source", "sourceStep", "exactEvidence", True),
    ("reject_wrong_target", "targetStep", "exactEvidence", True),
    ("reject_wrong_artifact", "artifactStep", "exactEvidence", True),
    ("reject_wrong_environment", "environmentStep", "exactEvidence", True),
    ("reject_wrong_policy", "policyStep", "exactEvidence", True),
    ("reject_wrong_owner", "ownerStep", "exactEvidence", True),
    ("reject_disabled_requester", "requesterGrantStep", "requesterAuthority", True),
    ("reject_stale_requester_epoch", "requesterEpochStep", "requesterAuthority", True),
    ("reject_foreign_verifier", "verifierAuthorityStep", "verifierAuthority", True),
    ("reject_disabled_verifier", "verifierGrantStep", "verifierAuthority", True),
    ("reject_stale_verifier_epoch", "verifierEpochStep", "verifierAuthority", True),
    ("reject_stale_version", "versionStep", "currentVersion", True),
    ("reject_wrong_profile", "wrongProfileStep", "currentProfile", True),
    ("reject_split_publication", "publicationStep", "atomicPublication", True),
    ("reject_duplicate_effect", "duplicateStep", "oneEffect", True),
    ("reject_terminal_overwrite", "overwriteStep", "terminalImmutable", True),
    ("reject_inconclusive_commit", "inconclusiveStep", "definitiveOnly", True),
    ("reject_effect_on_refusal", "sourceStep", "refusalsInert", True),
    ("reject_inconclusive_effect", "inconclusiveEffectStep", "inconclusiveInert", True),
    ("reject_inconclusive_version_change", "inconclusiveVersionStep", "inconclusiveInert", True),
    ("reject_retry_formal_effect", "retryEffectStep", "operatorRetryInert", True),
    ("reject_lost_outbox", "lostOutboxStep", "crashDurable", True),
    ("reject_foreign_read", "unauthorizedReadStep", "ownerReads", True),
    ("reject_foreign_retry", "unauthorizedRetryStep", "ownerRetries", True),
    ("reject_changed_retry_reply", "wrongReplyStep", "durableReplies", True),
    ("reject_unbounded_interference", "unboundedVersionStep", "bounded", True),
)


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_identity(root: Path) -> dict:
    """Same canonical distribution format as the frozen core toolchain lock."""
    root = root.resolve(strict=True)
    entries = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(root):
                raise ValueError(f"runtime symlink escapes distribution: {relative}")
            entries.append({"path": relative, "symlink": str(path.readlink())})
        elif path.is_file():
            entries.append({"path": relative, "bytes": path.stat().st_size, "sha256": sha(path)})
        elif not path.is_dir():
            raise ValueError(f"unsupported runtime file type: {relative}")
    return {"path": str(root), "sha256": hashlib.sha256(canonical(entries)).hexdigest(),
            "entries": len(entries), "bytes": sum(entry.get("bytes", 0) for entry in entries)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--quint-cli", type=Path, required=True)
    parser.add_argument("--java-bin", type=Path, required=True)
    parser.add_argument("--quint-home", type=Path, default=os.environ.get("QUINT_HOME"))
    parser.add_argument("--timeout-seconds", type=int, default=300,
                        help="per subprocess; expiration is a failure, never bounded success")
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    source = package / "formal/quint"
    output = args.output_dir.resolve()
    if (output == package or output in package.parents or output == source or
            source in output.parents or output == package / "tools" or package / "tools" in output.parents):
        parser.error("evidence must not overlap model or runner source directories")
    if output.exists() and any(output.iterdir()):
        parser.error("--output-dir must be absent or empty, so earlier evidence cannot be reused")
    if not 1 <= args.timeout_seconds <= 900:
        parser.error("--timeout-seconds must be between 1 and 900")
    if args.quint_home is None:
        parser.error("provide --quint-home or QUINT_HOME with the installed pinned Apalache distribution")
    output.mkdir(parents=True, exist_ok=True)
    model = source / "bridge.qnt"
    lockfile = package.parent / "research_exchange/toolchains.lock.json"
    source_paths = (model, source / "tlc.json", source / "README.md", Path(__file__).resolve(), lockfile)

    def source_identity() -> dict[str, str]:
        return {str(path.relative_to(package.parent)): sha(path) for path in source_paths}

    summary = {
        "schema": "formal-research-exchange/bridge-quint-evidence/v1",
        "status": "running",
        "source_sha256": source_identity(),
        "scope": {
            "domains": "one immutable submission/job/outbox, owner 1, foreign principal 2, internal verifier 3, two prepared workers, acceptance/rejection/inconclusive verdicts",
            "identity": "source is an equality abstraction of library/revision/snapshot/core identity; owner, target, artifact, environment, and policy are separately compared",
            "adversary": "worker 1 may substitute one binding field, verifier, or profile; worker 2 is exact; both independently choose any of three verdicts",
            "bounds": "one requester revoke/regrant and one verifier revoke/regrant (epochs 0..2); one profile rotation; one version-only interference; one operator retry; formal row versions 0..2; crashes/restarts may recur",
            "checking": "prepared results may race other workers, grant changes, profile rotation, version changes, pause/retry, and crash",
            "durability": "admission and terminal publication are atomic specification actions; before-commit crash preserves pending durable state, after-commit crash preserves the winner",
            "inconclusive": "pause/retry alter dispatch metadata only, including no formal row-version change; retry retains competing prepared tickets; a still-current definitive ticket can commit from pending or paused",
            "properties": "all reachable states of this finite transition system, verified to queue exhaustion; terminal effects and receipts include acceptance and rejection",
            "limits": "no unbounded theorem, liveness/fairness, checker truth, cryptographic authentication, SQLite/Elixir refinement, arbitrary identities/jobs/epochs/retries, or exactly-once physical checking claim",
            "request_identity": "payload canonicalization, same-ID changed-payload refusal, real subprocess boundaries, and actual durable database behavior remain concrete runtime-test obligations",
        },
        "checks": [],
    }

    def save() -> None:
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    def command(label: str, argv: list[str], env: dict[str, str]) -> tuple[int, str, dict]:
        directory = output / label
        directory.mkdir()
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
                 "log": str(logfile.relative_to(output)), "log_sha256": sha(logfile)}
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
        cli = args.quint_cli.resolve(strict=True)
        java = args.java_bin.resolve(strict=True)
        home = args.quint_home.resolve(strict=True)
        jar = home / f"apalache-dist-{APALACHE_VERSION}/apalache/lib/apalache.jar"
        node_name = shutil.which("node")
        if not node_name:
            raise RuntimeError("node is required on PATH")
        node = Path(node_name).resolve(strict=True)
        python = Path(sys.executable).resolve(strict=True)
        lock = json.loads(lockfile.read_text())
        if (lock["versions"]["quint"] != QUINT_VERSION or
                lock["versions"]["apalache"] != APALACHE_VERSION or
                lock["versions"]["jre"] != JRE_VERSION):
            raise RuntimeError("frozen core runtime lock does not name the required pinned versions")
        env = os.environ.copy()
        env["PATH"] = str(java.parent) + os.pathsep + env.get("PATH", "")
        env["QUINT_HOME"] = str(home)
        # Do not import project modules; source bytes are not bypassed by cached
        # Python bytecode. Node/Python/OS remain the recorded trusted environment.
        runtime_files = {"quint_cli": cli, "java": java, "apalache_jar": jar}
        runtime_trees = {"quint_node_modules": cli.parents[4], "jre": java.parent.parent}

        def runtime_identity() -> dict:
            return {"files": {name: {"path": str(path), "sha256": sha(path)}
                              for name, path in runtime_files.items()},
                    "trees": {name: tree_identity(path) for name, path in runtime_trees.items()},
                    "trusted_environment": {"node": {"path": str(node), "sha256": sha(node)},
                                            "python": {"path": str(python), "sha256": sha(python)}}}

        before = runtime_identity()
        summary["toolchain"] = {"quint": QUINT_VERSION, "apalache": APALACHE_VERSION,
                                "jre": JRE_VERSION, "identity": before}
        for name, identity in before["files"].items():
            if identity["sha256"] != lock["file_sha256"][name]:
                raise RuntimeError(f"pinned runtime file mismatch: {name}")
        for name, identity in before["trees"].items():
            if identity["sha256"] != lock["tree_sha256"][name]:
                raise RuntimeError(f"pinned runtime distribution mismatch: {name}")
        save()
        rc, log, entry = command("quint_version", [str(node), str(cli), "--version"], env)
        require(entry, rc == 0 and not entry["timed_out"] and log.strip() == QUINT_VERSION,
                "pinned CLI version and distribution identity")
        rc, log, entry = command("java_version", [str(java), "-version"], env)
        require(entry, rc == 0 and not entry["timed_out"] and 'version "21.0.13"' in log and
                "21.0.13+9" in log, "pinned Java version and distribution identity")
        rc, log, entry = command("bridge_typecheck", [str(node), str(cli), "typecheck", str(model)], env)
        require(entry, rc == 0 and not entry["timed_out"], "Quint static type and effect checking")
        rc, log, entry = command("bridge_scenarios", [str(node), str(cli), "test", str(model),
            "--main", "bridge", "--backend=typescript", "--seed", "123",
            "--max-samples", "1", "--verbosity", "2"], env)
        entry["scenario_count"] = SCENARIO_COUNT
        require(entry, rc == 0 and not entry["timed_out"] and
                re.search(rf'\b{SCENARIO_COUNT} passing\b', log) is not None,
                "deterministic transition scenarios")
        for label, step, invariant, negative in CASES:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            argv = [str(node), str(cli), "verify", str(model), "--main", "bridge",
                    "--init", "init", "--step", step, "--invariant", invariant,
                    "--backend=tlc", "--tlc-config", str(source / "tlc.json"),
                    "--apalache-version", APALACHE_VERSION,
                    "--server-endpoint", f"localhost:{port}", "--verbosity=3"]
            rc, log, entry = command(label, argv, env)
            entry.update({"step": step, "invariant": invariant, "negative_control": negative})
            correct_translator = f"# APALACHE version: {APALACHE_VERSION} |" in log
            if negative:
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
        summary["source_sha256_after"] = source_identity()
        if summary["source_sha256_after"] != summary["source_sha256"]:
            raise RuntimeError("model, runner, documentation, configuration, or runtime lock changed during checking")
        summary["runtime_identity_after"] = runtime_identity()
        if summary["runtime_identity_after"] != before:
            raise RuntimeError("runtime identity changed during checking")
        summary["status"] = "passed"
        summary["counts"] = {"exhaustive_models": 1, "scenarios": SCENARIO_COUNT,
                             "targeted_mutant_checks": len(CASES) - 1,
                             "distinct_mutant_actions": len({case[1] for case in CASES[1:]})}
        save()
        print(f"QUINT_BRIDGE_CHECKS_PASSED 1 exhaustive model; {SCENARIO_COUNT} scenarios; "
              f"{len(CASES) - 1} targeted mutant checks", flush=True)
        return 0
    except (OSError, RuntimeError, ValueError, KeyError) as exc:
        summary["status"] = "failed"
        summary["error"] = str(exc)
        save()
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
