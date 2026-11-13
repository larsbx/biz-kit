#!/usr/bin/env python3
"""Check the inert kernel and write separately classified, revision-bound receipts."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parent
TOOLCHAIN = ROOT.parent / "research_exchange" / "toolchains.lock.json"
MUTANTS = {
    "badRevision": "revisionSafe",
    "doubleSale": "noDoubleSale",
    "staleAppraisal": "valuationSafe",
    "unauthorized": "authoritySafe",
    "fakeOwnership": "ownershipSafe",
    "forgedReceipt": "receiptSafe",
    "replayTx": "oncePerTx",
    "replaySource": "oncePerSource",
    "underallocatedLoss": "lossSafe",
    "deficitPayout": "profitSafe",
    "unfundedPayout": "assetsSafe",
    "insolventPayout": "solvencySafe",
}
AXIOMS = {"propext", "Quot.sound", "Classical.choice"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    return subprocess.check_output(["git", "-C", ROOT, *args], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--lean", required=True, type=Path)
    parser.add_argument("--quint-cli", required=True, type=Path)
    parser.add_argument("--quint-home", required=True, type=Path)
    parser.add_argument("--java", required=True, type=Path)
    parser.add_argument("--app-path-adapter", type=Path)
    args = parser.parse_args()
    if git("status", "--porcelain", "--", ".", str(TOOLCHAIN)):
        parser.error("commit the kernel and toolchain lock before producing an exact-revision receipt")
    output = args.output.resolve()
    repo = Path(git("rev-parse", "--show-toplevel"))
    if output == repo or repo in output.parents:
        parser.error("write generated evidence outside the repository")
    output.mkdir(parents=True, exist_ok=False)

    lock = json.loads(TOOLCHAIN.read_text())
    versions = lock["versions"]
    lean, quint, java = [p.resolve(strict=True) for p in (args.lean, args.quint_cli, args.java)]
    home = args.quint_home.resolve(strict=True)
    node = Path(shutil.which("node")).resolve(strict=True)
    jar = home / f"apalache-dist-{versions['apalache']}/apalache/lib/apalache.jar"
    tools = {name: digest(path) for name, path in {
        "lean": lean, "leanshared": lean.parent.parent / "lib/lean/libleanshared.so",
        "quint_cli": quint, "java": java, "apalache_jar": jar, "node": node,
    }.items()}
    for name in tools.keys() & lock["file_sha256"].keys():
        if tools[name] != lock["file_sha256"][name]:
            raise RuntimeError(f"unexpected {name} executable or library digest")

    # Use the stock binaries. The optional pinned adapter addresses only executable lookup.
    env = dict(os.environ)
    env.pop("LD_PRELOAD", None)
    lean_env = dict(env, LEAN_PATH=str(output))
    if args.app_path_adapter:
        adapter = args.app_path_adapter.resolve(strict=True)
        tools["app_path_adapter"] = digest(adapter)
        if tools["app_path_adapter"] != lock["optional_file_sha256"]["application_path_adapter"]:
            raise RuntimeError("unexpected executable-location adapter digest")
        lean_env.update(LD_PRELOAD=str(adapter), FRE_LEAN_ROOT=str(lean.parent.parent))
    quint_env = dict(env, QUINT_HOME=str(home), PATH=str(java.parent) + os.pathsep + env["PATH"])
    receipt = {
        "schema": "biz-kit/producer-capital/verification-v1",
        "revision": git("rev-parse", "HEAD"),
        "tree": git("rev-parse", "HEAD^{tree}"),
        "status": "running",
        "tool_versions": versions,
        "tool_sha256": tools,
        "source_sha256": {str(p.relative_to(repo)): digest(p) for p in
                          [*(ROOT / p for p in git("ls-files", "--", ".").splitlines()), TOOLCHAIN]},
        "checks": {},
    }

    def save():
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    def run(name, argv, env, cwd=output):
        start = time.monotonic()
        with subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, start_new_session=True, text=True) as proc:
            try:
                log, _ = proc.communicate(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                log, _ = proc.communicate()
                log += "\nRUNNER_TIMEOUT\n"
        logfile = f"{name}.log"
        (output / logfile).write_text(log)
        return {"argv": list(map(str, argv)), "exit_code": proc.returncode, "log": logfile,
                "seconds": round(time.monotonic() - start, 3)}, log

    def require(name, entry, ok, evidence_class):
        entry.update(passed=bool(ok), evidence_class=evidence_class)
        receipt["checks"][name] = entry
        save()
        print(f"{name}: {'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            raise RuntimeError(f"{name}: expected evidence missing in {entry['log']}")

    def lean_run(name, args, cls, check=lambda _: True):
        entry, log = run(name, [lean, *args], lean_env, ROOT / "lean")
        require(name, entry, entry["exit_code"] == 0 and check(log), cls)
        return log

    def model_check(name, transition, invariant):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        entry, log = run(name, [node, quint, "verify", ROOT / "quint/capital.qnt",
            "--backend", "tlc", "--tlc-config", ROOT / "quint/tlc.json", "--step", transition,
            "--invariant", invariant, "--apalache-version", versions["apalache"],
            "--server-endpoint", f"localhost:{port}", "--verbosity", "3"], quint_env)
        entry.update(transition=transition, invariant=invariant)
        correct_translator = f"# APALACHE version: {versions['apalache']} |" in log
        if name != "quint_safety":
            ok = (entry["exit_code"] == 1 and correct_translator and
                  "Error: Invariant q_inv is violated." in log and
                  "Error: The behavior up to this point is:" in log and
                  "[violation] Found an issue" in log)
            return name, entry, ok, "expected Quint/TLC counterexample"
        stats = re.search(r"(\d+) states generated, (\d+) distinct states found, 0 states left on queue\.", log)
        depth = re.search(r"The depth of the complete state graph search is (\d+)\.", log)
        ok = (entry["exit_code"] == 0 and correct_translator and stats and depth and
              "Model checking completed. No error has been found." in log)
        if ok:
            entry["states"] = dict(generated=int(stats[1]), distinct=int(stats[2]), queued=0, depth=int(depth[1]))
        return name, entry, ok, "complete exploration of the finite Quint fixture"

    save()
    try:
        lean_run("lean_version", ["--version"], "tool identity", lambda log: versions["lean_commit"] in log)
        lean_run("lean_model", ["-o", output / "Capital.olean", "Capital.lean"], "Lean kernel acceptance")
        lean_run("lean_proofs", ["-o", output / "Proofs.olean", "Proofs.lean"], "Lean kernel acceptance")
        targets = re.findall(r"^theorem (\w+)", (ROOT / "lean/Proofs.lean").read_text(), re.M)
        audit = output / "Audit.lean"
        audit.write_text("import Proofs\n" + "".join(f"#print axioms ProducerCapital.{t}\n" for t in targets))

        def axioms_ok(log):
            reported = re.findall(r"'ProducerCapital\.(\w+)' (?:does not depend on any axioms|depends on axioms: \[([^\]]*)\])", log)
            return ([t for t, _ in reported] == targets and bool(targets) and
                    all(set(deps.split(", ")) <= AXIOMS for _, deps in reported if deps))

        lean_run("lean_axioms", [audit], "theorem dependency audit", axioms_ok)
        lean_run("lean_regressions", ["--run", "Regression.lean"], "executable Lean regressions",
                 lambda log: len(re.findall(r"^PASS ", log, re.M)) == 18)

        for name, argv, check, cls in [
            ("quint_version", [node, quint, "--version"], lambda s: s.strip() == versions["quint"], "tool identity"),
            ("java_version", [java, "-version"], lambda s: 'version "21.0.13"' in s, "tool identity"),
            ("quint_types", [node, quint, "typecheck", ROOT / "quint/capital.qnt"], lambda _: True,
             "Quint static checking"),
            ("quint_scenarios", [node, quint, "test", ROOT / "quint/capital.qnt", "--backend",
             "typescript", "--seed", "123", "--max-samples", "1"], lambda s: "7 passing" in s,
             "deterministic Quint scenarios"),
        ]:
            entry, log = run(name, argv, quint_env)
            require(name, entry, entry["exit_code"] == 0 and check(log), cls)
        require(*model_check("quint_safety", "step", "safety"))
        with ThreadPoolExecutor(max_workers=2) as pool:
            checks = [pool.submit(model_check, name, name, inv) for name, inv in MUTANTS.items()]
            for check in checks:
                require(*check.result())
        if git("rev-parse", "HEAD") != receipt["revision"] or any(
            digest(repo / name) != sha for name, sha in receipt["source_sha256"].items()
        ):
            raise RuntimeError("source or checkout changed during verification")
        receipt["status"] = "passed"
    except Exception as exc:
        receipt.update(status="failed", error=str(exc))
        raise
    finally:
        save()


if __name__ == "__main__":
    main()
