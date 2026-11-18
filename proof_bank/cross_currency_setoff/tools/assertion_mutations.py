#!/usr/bin/env python3
"""Require source mutants to fail their own intended assertions.

The baseline and mutants run through the identical direct-Elixir harness. A
structured ExUnit lifecycle receipt binds failure to specific baseline test IDs;
an unrelated assertion, startup error, skipped test or CLI summary cannot count.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "proof_bank/cross_currency_setoff"
SOURCE = ROOT / "apps/barter_core/lib/barter_core/cross_currency_setoff.ex"
TEST_FILES = [
    "apps/barter_core/test/cross_currency_setoff_test.exs",
    "apps/barter_core/test/cross_currency_setoff_formal_test.exs",
]
ORIGINAL_TEST = "BarterCore.CrossCurrencySetoffTest:test "
FORMAL_TEST = "BarterCore.CrossCurrencySetoffFormalTest:test "
MUTATIONS = {
    "omit-source-revision-preimage": (
        "Integer.to_string(source.revision),", '"revision-omitted",',
        [FORMAL_TEST + "self-consistency verification does not authenticate a latest source revision"],
    ),
    "omit-source-id-preimage": (
        "      source.id,\n      source.debtor,", '      "source-id-omitted",\n      source.debtor,',
        [ORIGINAL_TEST + "source ID substitution with identical nominal amounts changes the commitment"],
    ),
    "accept-expired-rate": (
        "is_integer(rate.valid_until) and rate.valid_until > now",
        "is_integer(rate.valid_until) and rate.valid_until >= now",
        [FORMAL_TEST + "agreement and source time boundaries are explicit host assertions"],
    ),
    "omit-full-candidate-equality": (
        "{:ok, ^candidate} -> {:ok, candidate}",
        "{:ok, _recomputed} -> {:ok, candidate}",
        [FORMAL_TEST + "rounding edits can conserve totals while violating the declared rational"],
    ),
    "discard-second-currency": (
        "totals_by_currency: totals,", "totals_by_currency: [hd(totals)],",
        [ORIGINAL_TEST + "cross-currency mutual offset produces two exact conserved currency ledgers"],
    ),
}


def validate_lifecycle(report: object, expected_files: list[str]) -> dict[str, dict]:
    keys = {"schema", "suite_started", "suite_finished", "interrupted", "declared", "started", "finished"}
    if (not isinstance(report, dict) or set(report) != keys or
            report["schema"] != "bizkit.cross-currency.assertion-suite.v1" or
            type(report["suite_started"]) is not int or report["suite_started"] != 1 or
            type(report["suite_finished"]) is not int or report["suite_finished"] != 1 or
            report["interrupted"] is not False or
            not all(isinstance(report[key], list) for key in ["declared", "started", "finished"])):
        raise ValueError("incomplete or malformed assertion-suite receipt")
    declared = report["declared"]
    if (not declared or not expected_files or len(expected_files) != len(set(expected_files)) or
            any(not isinstance(row, dict) or set(row) != {"id", "file"} or
                not all(isinstance(row[k], str) and row[k] for k in ["id", "file"])
                for row in declared)):
        raise ValueError("empty or malformed assertion test inventory")
    ids = [row["id"] for row in declared]
    if len(ids) != len(set(ids)) or {row["file"] for row in declared} != set(expected_files):
        raise ValueError("duplicate tests or incomplete assertion test files")
    if (len(report["started"]) != len(ids) or
            not all(isinstance(item, str) for item in report["started"]) or
            set(report["started"]) != set(ids)):
        raise ValueError("assertion tests did not all start exactly once")
    finished = report["finished"]
    if len(finished) != len(ids) or any(
        not isinstance(row, dict) or set(row) != {"id", "status", "failure_classes"} or
        not isinstance(row["id"], str) or row["status"] not in ["passed", "failed"] or
        not isinstance(row["failure_classes"], list) or
        any(not isinstance(item, str) for item in row["failure_classes"])
        for row in finished
    ) or {row["id"] for row in finished} != set(ids):
        raise ValueError("assertion tests did not all finish exactly once")
    for row in finished:
        failures = row["failure_classes"]
        if row["status"] == "passed" and failures:
            raise ValueError("passed test has failure details")
        if row["status"] == "failed" and (
            not failures or any(kind != "ExUnit.AssertionError" for kind in failures)
        ):
            raise ValueError("non-assertion test failure cannot detect a semantic mutant")
    return {row["id"]: row for row in finished}


def validate_baseline(report: object, expected_files: list[str]) -> dict[str, dict]:
    finished = validate_lifecycle(report, expected_files)
    if any(row["status"] != "passed" for row in finished.values()):
        raise ValueError("identical-invocation assertion baseline must pass every test")
    return finished


def validate_mutant(report: object, baseline: dict, expected_files: list[str],
                    required_failures: list[str]) -> list[str]:
    baseline_finished = validate_baseline(baseline, expected_files)
    finished = validate_lifecycle(report, expected_files)
    if ({row["id"]: row["file"] for row in report["declared"]} !=
            {row["id"]: row["file"] for row in baseline["declared"]}):
        raise ValueError("mutant test inventory differs from passing baseline")
    if (not required_failures or len(required_failures) != len(set(required_failures)) or
            any(test not in baseline_finished for test in required_failures)):
        raise ValueError("missing or invalid intended mutant test identities")
    failed = sorted(test for test, row in finished.items() if row["status"] == "failed")
    if not set(required_failures).issubset(failed):
        raise ValueError("mutant did not fail every intended source-specific assertion")
    return failed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elixir-bin", default="elixir")
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.out_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    original = SOURCE.read_text()
    env = dict(os.environ)

    def execute(label: str, source: Path) -> tuple[subprocess.CompletedProcess, dict]:
        target = output / (label + ".json")
        env["SETOFF_ASSERTION_RECEIPT"] = str(target)
        command = [args.elixir_bin,
                   "-r", str(ROOT / "apps/barter_core/lib/barter_core.ex"),
                   "-r", str(source),
                   "-r", str(PROJECT / "elixir/assertion_receipt.exs"),
                   "-r", str(ROOT / "apps/barter_core/test/test_helper.exs")]
        for path in TEST_FILES:
            command.extend(["-r", str(ROOT / path)])
        command.extend(["-e", "ExUnit.configure(seed: 341, formatters: "
                        "[ExUnit.CLIFormatter, CrossCurrencySetoff.AssertionReceipt])"])
        result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True,
                                timeout=180, check=False)
        (output / (label + ".stdout")).write_text(result.stdout)
        (output / (label + ".stderr")).write_text(result.stderr)
        (output / (label + "-command.json")).write_text(json.dumps(command, indent=2) + "\n")
        if not target.is_file():
            raise RuntimeError(label + " produced no complete assertion receipt")
        return result, json.loads(target.read_text())

    baseline_result, baseline = execute("baseline", SOURCE)
    if baseline_result.returncode != 0:
        raise RuntimeError("identical-invocation assertion baseline did not exit successfully")
    baseline_finished = validate_baseline(baseline, TEST_FILES)
    mutations = []
    with tempfile.TemporaryDirectory(prefix="setoff-assertion-mutants-") as build:
        for name, (needle, replacement, required) in MUTATIONS.items():
            if original.count(needle) != 1:
                raise RuntimeError("changed assertion mutation anchor: " + name)
            changed = original.replace(needle, replacement)
            mutant = Path(build) / (name + ".ex")
            mutant.write_text(changed)
            result, report = execute(name, mutant)
            if result.returncode != 2:
                raise RuntimeError(name + " did not finish with ExUnit assertion failure status")
            failures = validate_mutant(report, baseline, TEST_FILES, required)
            mutations.append({"name": name, "status": "detected",
                              "required_failure_ids": required, "observed_failure_ids": failures,
                              "failed_tests": len(failures),
                              "mutated_source_sha256": hashlib.sha256(changed.encode()).hexdigest()})
    print(json.dumps({
        "schema": "bizkit.cross-currency.assertion-mutations.v1",
        "source_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "baseline": {"tests": len(baseline_finished), "status": "passed",
                     "test_ids": sorted(baseline_finished)},
        "mutations": mutations,
    }, indent=2))


if __name__ == "__main__":
    main()
