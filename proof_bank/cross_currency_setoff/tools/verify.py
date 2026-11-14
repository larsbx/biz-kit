#!/usr/bin/env python3
"""Rebuild and compare the inert preview; emit an unsigned, source-bound receipt.

No stage writes a business event, authenticates a contract, or invokes settlement.
By default a clean checkout and its explicit expected Git head are required.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "proof_bank/cross_currency_setoff"
MAX_MINOR = 9_007_199_254_740_991
ALLOWED_AXIOMS = {"propext", "Quot.sound", "Classical.choice"}
SOURCE = ROOT / "apps/barter_core/lib/barter_core/cross_currency_setoff.ex"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def source_manifest() -> dict[str, str]:
    paths = [ROOT / ".github/workflows/cross-currency-setoff-proof.yml",
             ROOT / ".github/workflows/barter-core.yml",
             ROOT / ".github/workflows/commercial-clearing-acceptance.yml",
             ROOT / "formal/lean/install-toolchain.sh", ROOT / "formal/lean/lean-toolchain",
             ROOT / "apps/barter_core/README.md",
             ROOT / "docs/architecture/2026-11-08-cross-currency-commercial-setoff-preview.md",
             ROOT / "mix.exs", ROOT / "mix.lock"]
    paths += list((ROOT / "apps/barter_core").rglob("*.ex"))
    paths += list((ROOT / "apps/barter_core").rglob("*.exs"))
    paths += list((ROOT / "config").glob("*.exs"))
    paths += list((ROOT / "apps/coop_substrate/lib/coop_substrate").glob("commercial_setoff*.ex"))
    paths += list((ROOT / "apps/coop_substrate/test").glob("commercial_setoff*_test.exs"))
    paths += [p for p in PROJECT.rglob("*") if p.is_file() and
              not any(x in p.relative_to(PROJECT).parts for x in
                      ["node_modules", "evidence", "__pycache__", ".lake"]) and
              p.suffix in [".py", ".lean", ".qnt", ".json", ".exs", ".md", ".toml", ".c"]]
    paths += [PROJECT / "lean/lean-toolchain"]
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(set(paths))}


def require_head_sources(manifest: dict[str, str]) -> None:
    """Reject ignored/untracked injected source, not only ordinary Git dirt."""
    tracked = set(git("ls-tree", "-r", "--name-only", "HEAD").splitlines())
    for path, digest in manifest.items():
        if path not in tracked:
            raise ValueError("source is not present in HEAD: " + path)
        blob = subprocess.check_output(["git", "show", "HEAD:" + path], cwd=ROOT)
        if hashlib.sha256(blob).hexdigest() != digest:
            raise ValueError("source bytes differ from HEAD: " + path)


def audit_axioms(output: str, expected: list[str]) -> dict[str, list[str]]:
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    found = {}
    for name, content in re.findall(pattern, output):
        if name in found:
            raise ValueError("duplicate axiom result: " + name)
        axioms = [x.strip() for x in content.split(",") if x.strip()]
        if set(axioms) - ALLOWED_AXIOMS:
            raise ValueError("unapproved axioms: " + name + ": " + str(axioms))
        found[name] = axioms
    if set(found) != set(expected) or len(expected) != len(set(expected)):
        raise ValueError("incomplete or unexpected axiom inventory")
    return found


def rows_tsv(rows: list[tuple[int, ...]]) -> str:
    return "".join("\t".join(map(str, row)) + "\n" for row in rows)


def parse_rows(text: str, count: int) -> list[tuple[int, ...]]:
    rows = [tuple(int(x) for x in line.split("\t")) for line in text.splitlines()]
    if len(rows) != count or any(len(row) != 5 for row in rows):
        raise ValueError("missing, extra, or malformed comparison rows")
    return rows


def boundaries() -> list[tuple[int, int, int, int]]:
    values = [0, 1, 2, 3, MAX_MINOR - 1, MAX_MINOR, MAX_MINOR + 1]
    rates = [(1, 1), (1, 2), (2, 1), (3, 2), (2, 3),
             (MAX_MINOR, MAX_MINOR - 1), (MAX_MINOR - 1, MAX_MINOR),
             (1, MAX_MINOR), (MAX_MINOR, 1), (MAX_MINOR, MAX_MINOR),
             (MAX_MINOR + 1, 1), (1, MAX_MINOR + 1), (0, 1), (1, 0), (6, 4)]
    rows = list(itertools.product(values, values))
    result = [(q, b, n, d) for q, b in rows for n, d in rates]
    rng = random.Random(341_20261109)
    for _ in range(256):
        q, b, n, d = (rng.randrange(1, MAX_MINOR + 1) for _ in range(4))
        divisor = math.gcd(n, d)
        result.append((q, b, n // divisor, d // divisor))
    result.append((1_000_000, 800_000, 11, 10))
    return result


def check_observations(inputs: list[tuple[int, ...]], outputs: list[tuple[int, ...]]) -> None:
    for (q, b, n, d), (status, qr, br, qleft, bleft) in zip(inputs, outputs, strict=True):
        valid = all(0 < x <= MAX_MINOR for x in [q, b, n, d]) and math.gcd(n, d) == 1
        if not valid:
            if (status, qr, br, qleft, bleft) != (0, 0, 0, q, b):
                raise ValueError("invalid/canonicality gate disagrees")
        elif status == 1:
            if (qr, br, qleft, bleft) != (0, 0, q, b) or not (q < n or b < d):
                raise ValueError("refusal without absence of a positive rate quantum")
        elif status == 2:
            if not (0 < qr <= q and 0 < br <= b and qleft >= 0 and bleft >= 0 and
                    qr + qleft == q and br + bleft == b and n * br == d * qr and
                    qr % n == 0 and br % d == 0 and (qleft < n or bleft < d)):
                raise ValueError("exactness/conservation/maximality observation failed")
        else:
            raise ValueError("unexpected status")


def check_suite_receipt(report: object, expected_files: list[str]) -> dict[str, object]:
    """Require one complete, unfiltered ExUnit inventory with no missing tests.

    The total follows the current suite; adding tests must not break a constant
    count, and a zero-test/filtered/aborted run must not count as acceptance.
    The ordinary unfiltered `mix test` remains responsible for discovery.
    """
    keys = {"schema", "suite_started", "suite_finished", "interrupted",
            "declared", "started", "finished"}
    if (not isinstance(report, dict) or set(report) != keys or
            report["schema"] != "bizkit.cross-currency.barter-suite.v1" or
            type(report["suite_started"]) is not int or report["suite_started"] != 1 or
            type(report["suite_finished"]) is not int or report["suite_finished"] != 1 or
            report["interrupted"] is not False or
            not all(isinstance(report[key], list) for key in ["declared", "started", "finished"])):
        raise ValueError("incomplete or malformed Barter suite receipt")
    declared, started, finished = report["declared"], report["started"], report["finished"]
    if not declared or not expected_files or len(set(expected_files)) != len(expected_files):
        raise ValueError("empty or duplicate Barter suite inventory")
    if any(not isinstance(row, dict) or set(row) != {"id", "file"} or
           not all(isinstance(row[key], str) and row[key] for key in ["id", "file"])
           for row in declared):
        raise ValueError("malformed declared Barter tests")
    ids = [row["id"] for row in declared]
    if len(set(ids)) != len(ids) or {row["file"] for row in declared} != set(expected_files):
        raise ValueError("duplicate tests or incomplete Barter test file coverage")
    if (not all(isinstance(item, str) for item in started) or
            len(started) != len(ids) or set(started) != set(ids)):
        raise ValueError("not every declared Barter test started exactly once")
    if (any(not isinstance(row, dict) or set(row) != {"id", "status"} or
            not isinstance(row["id"], str) or row["status"] != "passed" for row in finished) or
            len(finished) != len(ids) or {row["id"] for row in finished} != set(ids)):
        raise ValueError("not every declared Barter test passed exactly once")
    return {"tests": len(ids), "failures": 0, "skipped": 0, "excluded": 0,
            "files": sorted(expected_files), "status": "passed"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--lean-bin", default="lean")
    parser.add_argument("--quint-cli", default="quint")
    parser.add_argument("--elixir-bin", default="elixir")
    parser.add_argument("--app-path-adapter", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-dirty", action="store_true", help="development only; receipt is not clean-head evidence")
    args = parser.parse_args()
    actual_head = git("rev-parse", "HEAD")
    if actual_head != args.expected_head:
        parser.error("checkout does not match --expected-head")
    dirty = git("status", "--porcelain", "--untracked-files=all")
    if dirty and not args.allow_dirty:
        parser.error("clean exact-head verification refuses tracked/untracked source changes")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    initial_sources = source_manifest()
    if not args.allow_dirty:
        require_head_sources(initial_sources)
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    binaries = {}
    for name, supplied in [("lean", args.lean_bin), ("quint", args.quint_cli), ("elixir", args.elixir_bin)]:
        path = shutil.which(supplied)
        if not path:
            parser.error("missing executable: " + supplied)
        binaries[name] = Path(path).resolve()
    env["PATH"] = str(binaries["lean"].parent) + os.pathsep + env["PATH"]
    # A local PID-namespace adapter changes application-path lookup only. It is
    # optional, explicit, fingerprinted, and unused on normal hosted runners.
    if args.app_path_adapter:
        adapter = args.app_path_adapter.resolve()
        env["LD_PRELOAD"] = str(adapter)
        binaries["application_path_adapter"] = adapter
    elif env.get("LD_PRELOAD"):
        parser.error("declare an application-path adapter explicitly instead of inherited LD_PRELOAD")
    binaries["python"] = Path(sys.executable).resolve()
    binaries["node"] = Path(shutil.which("node") or "").resolve()
    binaries["leanchecker"] = binaries["lean"].with_name("leanchecker")
    binaries["leanshared"] = binaries["lean"].parent.parent / "lib/lean/libleanshared.so"
    binaries["mix"] = binaries["elixir"].with_name("mix")
    binaries["erl"] = Path(shutil.which("erl") or "").resolve()
    receipt = {
        "schema": "bizkit-cross-currency-preview-verification/v1",
        "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "git_head": actual_head, "expected_head": args.expected_head,
        "clean_checkout": not bool(dirty), "dirty_paths": dirty.splitlines(),
        "source_sha256": hashlib.sha256(canonical(initial_sources).encode()).hexdigest(),
        "source_files": initial_sources, "signature": None,
        "runtime_identity": {name: {"path": str(path), "sha256": sha(path)} for name, path in binaries.items()},
        "runtime_scope": "entrypoints and Lean shared library fingerprinted; tool libraries, OS and runner remain trusted",
        "scope": "pure unsigned preview arithmetic and asserted-record consistency",
        "authority": "host assertions unverified; no debt discharge, accounting, payments or FX",
        "stages": [], "status": "running",
    }
    receipt_path = output / "receipt.json"

    def save() -> None:
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")

    def run(label: str, command: list[str], *, cwd: Path = ROOT, stdin: str | None = None,
            allowed: tuple[int, ...] = (0,), timeout: int = 180) -> subprocess.CompletedProcess[str]:
        print("RUN " + label, flush=True)
        started = time.monotonic()
        try:
            result = subprocess.run(command, cwd=cwd, env=env, input=stdin, text=True,
                                    capture_output=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as exc:
            receipt["stages"].append({"name": label, "command": command, "status": "timeout"})
            save()
            raise RuntimeError("timeout: " + label) from exc
        (output / (label + ".stdout")).write_text(result.stdout)
        (output / (label + ".stderr")).write_text(result.stderr)
        status = "passed" if result.returncode in allowed else "failed"
        receipt["stages"].append({"name": label, "command": command,
                                  "cwd": str(cwd), "exit_code": result.returncode,
                                  "status": status, "elapsed_seconds": round(time.monotonic() - started, 3)})
        save()
        if status != "passed":
            raise RuntimeError(label + " failed; see retained stdout/stderr")
        return result

    try:
        run("receipt-negative-controls", [sys.executable, "-I", str(PROJECT / "tools/test_receipt_guards.py")])
        versions = {}
        for name in ["lean", "quint", "elixir"]:
            versions[name] = run(name + "-version", [str(binaries[name]), "--version"]).stdout.strip()
        if not re.search(r"\bversion 4\.35\.0(?:,|\s|$)", versions["lean"]) or versions["quint"] != "0.33.1" or not re.search(r"\bElixir 1\.19\.0(?:\s|$)", versions["elixir"]):
            raise RuntimeError("unexpected version; toolchain contract is Lean4.35.0 / Quint0.33.1 / Elixir1.19.0")
        receipt["versions"] = versions
        with tempfile.TemporaryDirectory(prefix="setoff-lean-build-") as build_dir:
            build = Path(build_dir)
            env["LEAN_PATH"] = str(build)
            lean_dir = PROJECT / "lean"
            for module in ["CrossCurrencySetoff", "Contracts"]:
                run("lean-" + module, [str(binaries["lean"]), "-DwarningAsError=true", "-o", str(build / (module + ".olean")), module + ".lean"], cwd=lean_dir)
            registry = json.loads((lean_dir / "proof_targets.json").read_text())
            targets = registry["theorems"]
            if (registry.get("schema") != "bizkit.cross-currency-setoff.lean-targets.v1" or
                    registry.get("expected_count") != 40 or len(targets) != 40 or
                    set(registry.get("allowed_axioms", [])) != ALLOWED_AXIOMS):
                raise RuntimeError("changed theorem inventory contract")
            audit = run("lean-axioms", [str(binaries["lean"]), "-DwarningAsError=true", "AxiomAudit.lean"], cwd=lean_dir)
            receipt["axioms"] = audit_axioms(audit.stdout, targets)
            receipt["theorem_count"] = len(targets)
            # Fresh replay is a second execution of Lean's own kernel, not an
            # independently implemented verifier or proof of the Elixir runtime.
            run("lean-fresh-kernel", [str(binaries["leanchecker"]), "--fresh", "--verbose", "CrossCurrencySetoff"], cwd=lean_dir, timeout=300)
            negative = build / "FalseRounding.lean"
            negative.write_text("import CrossCurrencySetoff\nopen CrossCurrencySetoff\n"
                                "example : quoteReduction 10 1 3 2 = 1 := by decide\n")
            false_rounding = run("lean-false-rounding", [str(binaries["lean"]), str(negative)], cwd=build, allowed=(1,))
            if "decide" not in false_rounding.stdout or "error:" not in false_rounding.stdout:
                raise RuntimeError("false rounding was not rejected for a proof error")
            injected = build / "AxiomControl.lean"
            injected.write_text("import CrossCurrencySetoff\nnamespace NegativeControl\n"
                                "axiom fabricated : False\ntheorem injected : False := fabricated\n"
                                "#print axioms injected\nend NegativeControl\n")
            custom = run("lean-injected-axiom", [str(binaries["lean"]), str(injected)], cwd=build)
            try:
                audit_axioms(custom.stdout, ["NegativeControl.injected"])
            except ValueError as exc:
                if not str(exc).startswith("unapproved axioms:"):
                    raise
            else:
                raise RuntimeError("custom axiom was admitted by audit")
            placeholder = build / "PlaceholderControl.lean"
            placeholder.write_text("example : False := by sorry\n")
            placeholder_result = run("lean-placeholder", [str(binaries["lean"]), "-DwarningAsError=true", str(placeholder)], cwd=build, allowed=(1,))
            if not re.search(r"error: declaration uses [`']?sorry", placeholder_result.stdout):
                raise RuntimeError("unregistered contract placeholder was not rejected for the intended reason")
            receipt["lean_negative_controls"] = ["false rounding proof rejected", "custom axiom rejected by audit", "unregistered contract placeholder rejected"]
            small = list(itertools.product(range(9), range(9), range(6), range(6)))
            large = boundaries()
            for corpus, inputs, with_quint in [("bounded", small, True), ("boundary", large, False)]:
                data = rows_tsv(inputs)
                (output / (corpus + "-inputs.tsv")).write_text(data)
                lean = run(corpus + "-lean", [str(binaries["lean"]), "-DwarningAsError=true", "--run", "Eval.lean"], cwd=lean_dir, stdin=data)
                elixir = run(corpus + "-elixir", [str(binaries["elixir"]), str(PROJECT / "elixir/evaluate.exs")], stdin=data)
                lean_rows, elixir_rows = parse_rows(lean.stdout, len(inputs)), parse_rows(elixir.stdout, len(inputs))
                if lean_rows != elixir_rows:
                    raise RuntimeError(corpus + " Lean/Elixir mismatch")
                check_observations(inputs, elixir_rows)
                if with_quint:
                    quint = run(corpus + "-quint", [sys.executable, str(PROJECT / "quint/evaluate.py"), "--quint-cli", str(binaries["quint"])], stdin=data)
                    if parse_rows(quint.stdout, len(inputs)) != lean_rows:
                        raise RuntimeError("independent Quint oracle mismatch")
                receipt[corpus + "_comparison"] = {"rows": len(inputs), "status": "passed",
                    "languages": ["Lean", "Elixir"] + (["Quint"] if with_quint else []),
                    "input_sha256": hashlib.sha256(data.encode()).hexdigest(),
                    "result_sha256": hashlib.sha256(lean.stdout.encode()).hexdigest()}
            # Execute actual implementation mutants: syntactically valid altered
            # programs must produce a semantic mismatch, not just crash.
            original = SOURCE.read_text()
            mutations = {
                "noncanonical-rate": ("Integer.gcd(rate.numerator, rate.denominator) != 1", "false"),
                "min-to-max": ("min(div(base_available, d), div(quote_available, n))", "max(div(base_available, d), div(quote_available, n))"),
                "inverted-rate": ("min(div(base_available, d), div(quote_available, n))", "min(div(base_available, n), div(quote_available, d))"),
                "rounding-up-quote": ("{:ok, multiples * n, multiples * d}", "{:ok, multiples * n + 1, multiples * d}"),
                "wrong-currency-residual": ("residual_minor: source.amount_minor - reduction", "residual_minor: 0"),
            }
            receipt["elixir_mutations"] = []
            expected_rows = parse_rows((output / "bounded-elixir.stdout").read_text(), len(small))
            for name, (needle, replacement) in mutations.items():
                if original.count(needle) != 1:
                    raise RuntimeError("changed mutation anchor: " + name)
                mutant = build / (name + ".ex")
                mutant.write_text(original.replace(needle, replacement))
                result = run("elixir-mutant-" + name, [str(binaries["elixir"]), str(PROJECT / "elixir/evaluate.exs"), str(mutant)], stdin=rows_tsv(small))
                different = sum(a != b for a, b in zip(parse_rows(result.stdout, len(small)), expected_rows, strict=True))
                if not different:
                    raise RuntimeError("undetected Elixir mutant: " + name)
                receipt["elixir_mutations"].append({"name": name, "mismatched_rows": different, "status": "detected"})
            assertion_mutants = {
                "omit-source-revision-preimage": ("Integer.to_string(source.revision),", '"revision-omitted",'),
                "omit-source-id-preimage": ("      source.id,\n      source.debtor,", '      "source-id-omitted",\n      source.debtor,'),
                "accept-expired-rate": ("is_integer(rate.valid_until) and rate.valid_until > now", "is_integer(rate.valid_until) and rate.valid_until >= now"),
                "omit-full-candidate-equality": ("{:ok, ^candidate} -> {:ok, candidate}", "{:ok, _recomputed} -> {:ok, candidate}"),
                "discard-second-currency": ("totals_by_currency: totals,", "totals_by_currency: [hd(totals)],"),
            }
            receipt["elixir_assertion_mutations"] = []
            for name, (needle, replacement) in assertion_mutants.items():
                if original.count(needle) != 1:
                    raise RuntimeError("changed assertion mutation anchor: " + name)
                mutant = build / (name + ".ex")
                mutant.write_text(original.replace(needle, replacement))
                command = [str(binaries["elixir"]),
                           "-r", str(ROOT / "apps/barter_core/lib/barter_core.ex"),
                           "-r", str(mutant),
                           "-r", str(ROOT / "apps/barter_core/test/test_helper.exs"),
                           "-r", str(ROOT / "apps/barter_core/test/cross_currency_setoff_test.exs"),
                           "-r", str(ROOT / "apps/barter_core/test/cross_currency_setoff_formal_test.exs"),
                           "-e", "ExUnit.configure(seed: 341)"]
                result = run("elixir-assertion-mutant-" + name, command, allowed=(2,))
                failed_tests = re.search(r"(?m)^19 tests, ([1-9][0-9]*) failures\s*$", result.stdout)
                if not failed_tests or not re.search(r"Assertion|Refute|match \(=\) failed", result.stdout):
                    raise RuntimeError("assertion mutant was not rejected by the full intended test inventory: " + name)
                receipt["elixir_assertion_mutations"].append({"name": name, "failed_tests": int(failed_tests.group(1)), "status": "detected"})
        quint_check = run("quint-tests-and-mutations", [sys.executable, str(PROJECT / "quint/check.py"), "--quint-cli", str(binaries["quint"]), "--out-dir", str(output / "quint-logs")], timeout=600)
        receipt["quint"] = json.loads(quint_check.stdout)
        with tempfile.TemporaryDirectory(prefix="setoff-mix-build-") as mix_build:
            env["MIX_BUILD_PATH"] = mix_build
            suite_receipt = output / "barter-suite.json"
            env["BARTER_SUITE_RECEIPT"] = str(suite_receipt)
            run("barter-suite", [str(binaries["elixir"]),
                "-r", str(PROJECT / "elixir/suite_receipt.exs"),
                str(binaries["mix"]), "test", "--formatter", "ExUnit.CLIFormatter",
                "--formatter", "CrossCurrencySetoff.SuiteReceipt"], cwd=ROOT / "apps/barter_core")
        env.pop("MIX_BUILD_PATH", None)
        env.pop("BARTER_SUITE_RECEIPT", None)
        expected_files = [p.relative_to(ROOT / "apps/barter_core").as_posix()
                          for p in sorted((ROOT / "apps/barter_core/test").rglob("*_test.exs"))]
        receipt["barter_suite"] = check_suite_receipt(json.loads(suite_receipt.read_text()), expected_files)
        run("barter-format", [str(binaries["elixir"].with_name("mix")), "format", "--check-formatted", "mix.exs", "lib/**/*.ex", "test/**/*.exs", "../../proof_bank/cross_currency_setoff/elixir/*.exs"], cwd=ROOT / "apps/barter_core")
        commercial = [f"../coop_substrate/{folder}/commercial_setoff{suffix}.{ext}" for folder, ext in [("lib/coop_substrate", "ex"), ("test", "exs")] for suffix in (["", "_proof", "_sources"] if ext == "ex" else ["_test", "_proof_test", "_sources_test"])]
        run("commercial-scoped-format", [str(binaries["elixir"].with_name("mix")), "format", "--check-formatted", *commercial], cwd=ROOT / "apps/barter_core")
        run("format-only-ast", [str(binaries["elixir"]), str(PROJECT / "elixir/format_only.exs")])
        if source_manifest() != initial_sources or git("rev-parse", "HEAD") != actual_head:
            raise RuntimeError("source changed during verification")
        for name, path in binaries.items():
            if sha(path) != receipt["runtime_identity"][name]["sha256"]:
                raise RuntimeError("runtime entrypoint changed during verification: " + name)
        if not args.allow_dirty and git("status", "--porcelain", "--untracked-files=all"):
            raise RuntimeError("verification modified the checkout")
        receipt["status"] = "passed"
    except Exception as exc:
        receipt["status"] = "failed"
        receipt["error"] = str(exc)
    receipt["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    receipt["artifacts"] = {p.relative_to(output).as_posix(): sha(p) for p in sorted(output.rglob("*")) if p.is_file() and p != receipt_path}
    save()
    print(json.dumps({"status": receipt["status"], "receipt": str(receipt_path),
                      "git_head": actual_head, "clean_checkout": receipt["clean_checkout"]}), flush=True)
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
