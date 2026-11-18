#!/usr/bin/env python3
"""Require real MCP admission, bounded Lean replay and interruption recovery without skips."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))

from research_exchange_bridge import source
from research_exchange_bridge.common import canonical, loads, sha
from research_exchange_bridge.tools.run_acceptance import beam_identity, cases
from adapter_pilot.checker import ControlledChecker

REQUIRED_CASES = frozenset({
    "test_materialization",
    "test_prohibited_axiom_report",
    "test_process_bounds",
    "test_dependency_fingerprint",
    "test_export_budget_is_bound_to_the_stored_policy",
    "test_guarded_replay_and_recovery",
    "test_mcp_source_roundtrip_binds_real_replay",
    "test_mcp_legacy_source_profile_keeps_policy_and_replay",
    "test_mcp_source_binding_and_profile_refusals",
})
MCP_CASES = ("test_mcp_source_roundtrip_binds_real_replay",
             "test_mcp_legacy_source_profile_keeps_policy_and_replay",
             "test_mcp_source_binding_and_profile_refusals")


def validate_inventory(names):
    if set(names) != REQUIRED_CASES or len(names) != len(set(names)):
        raise ValueError("required source acceptance cases are missing, duplicated or unregistered")


class CaseResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.executed_cases = []

    def startTest(self, test):
        self.executed_cases.append(test.id().rsplit(".", 1)[-1])
        super().startTest(test)


def validate_result(discovered, result):
    validate_inventory(discovered)
    validate_inventory(result.executed_cases)
    if (result.testsRun != len(discovered) or not result.wasSuccessful() or result.skipped or
            result.expectedFailures or result.unexpectedSuccesses or
            sorted(result.executed_cases) != sorted(discovered)):
        raise ValueError("every required source acceptance case must execute and pass without skips")


def validate_evidence(output, environment):
    recovery = loads((output / "interruption-recovery.json").read_bytes())
    if (recovery["mathematical_acceptance"] is not True or recovery["credit_issuance"] is not False or
            type(recovery["state_version"]) is not int or recovery["state_version"] != 1 or
            recovery["binding"]["environment_sha256"] != environment):
        raise ValueError("real interruption/recovery must preserve the admitted source environment")
    source.validate_evidence(recovery["controlled_check"], recovery["binding"], source.profile_for(environment),
                             recovery["submitted_source"].encode("utf-8"))
    if not recovery["database_observation"]["effects"]:
        raise ValueError("interruption/recovery must retain its actual committed SQLite observation")
    for name in MCP_CASES:
        evidence = loads((output / "cases" / (name + ".json")).read_bytes())
        if evidence.get("test") != name or not evidence.get("clients"):
            raise ValueError("real MCP case evidence is missing: " + name)
    for name in MCP_CASES[:2]:
        success = loads((output / "cases" / (name + ".json")).read_bytes())
        if not any(item["observation"]["effects"] and
                   item["observation"]["receipt"]["payload"]["mathematical_acceptance"] is True
                   for item in success["database_observations"]):
            raise ValueError("both source policy variants must retain their real MCP committed SQLite observations")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-root", required=True, type=Path)
    parser.add_argument("--source-imports", required=True, type=Path)
    parser.add_argument("--elixir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit("Source acceptance output must be a new or empty directory")
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic_ns()
    phase = "preflight"
    summary = {"schema": "research-exchange/source-runtime-acceptance/v1", "status": "failed",
               "scope": source.SCOPE, "mathlib_revision": source.REVISION,
               "required_cases": sorted(REQUIRED_CASES), "tests": 0, "skips": 0}
    try:
        lean = args.lean_root.resolve(strict=True)
        imports = args.source_imports.resolve(strict=True)
        elixir = args.elixir.resolve(strict=True)
        if not os.access("/usr/bin/prlimit", os.X_OK):
            raise ValueError("the required /usr/bin/prlimit executable is unavailable")
        checker = ControlledChecker(lean)
        environment_before = source.environment_identity(checker, imports)
        environment = dict(os.environ)
        environment["PATH"] = str(elixir.parent) + os.pathsep + environment.get("PATH", "")
        beam = beam_identity(elixir, environment)
        summary.update(environment_sha256=environment_before, imports_sha256=source.dependency_identity(imports),
                       checker_sha256=checker.identities(), beam=beam, python=sys.version.split()[0])
        # Configure before discovery: the real test class's skip decorator is
        # evaluated on import. Missing prerequisites must fail preflight.
        os.environ.update(environment)
        os.environ.update(EXCHANGE_LEAN_ROOT=str(lean), EXCHANGE_SOURCE_IMPORTS=str(imports),
                          EXCHANGE_SOURCE_ELIXIR=str(elixir),
                          EXCHANGE_SOURCE_ACCEPTANCE_OUTPUT=str(output / "cases"),
                          EXCHANGE_SOURCE_EVIDENCE=str(output / "interruption-recovery.json"))
        (output / "cases").mkdir()
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), pattern="test_source.py",
                                                  top_level_dir=str(ROOT.parent))
        discovered = list(cases(suite))
        summary["discovered_cases"] = sorted(discovered)
        validate_inventory(discovered)
        phase = "acceptance"
        with (output / "acceptance.log").open("w") as log:
            result = unittest.TextTestRunner(stream=log, verbosity=2, resultclass=CaseResult).run(suite)
        summary.update(tests=result.testsRun, skips=len(result.skipped), failures=len(result.failures),
                       errors=len(result.errors), executed_cases=result.executed_cases,
                       expected_failures=len(result.expectedFailures), unexpected_successes=len(result.unexpectedSuccesses),
                       skipped_cases=[{"test": test.id(), "reason": reason} for test, reason in result.skipped])
        environment_after = source.environment_identity(checker, imports)
        summary.update(environment_after_sha256=environment_after,
                       environment_unchanged=environment_before == environment_after)
        if environment_before != environment_after:
            raise ValueError("the pinned source environment changed during acceptance")
        validate_result(discovered, result)
        phase = "evidence"
        validate_evidence(output, environment_before)
        summary["status"] = "passed"
    except Exception as error:
        summary.update(failure_phase=phase, error=f"{type(error).__name__}: {error}")
        print(summary["error"], file=sys.stderr)
        log = output / "acceptance.log"
        if log.exists():
            print(log.read_text()[-12_000:], file=sys.stderr)
    summary["duration_ns"] = time.monotonic_ns() - started
    summary["artifacts"] = [{"path": path.relative_to(output).as_posix(), "sha256": sha(path.read_bytes())}
                            for path in sorted(output.rglob("*")) if path.is_file()]
    (output / "summary.json").write_bytes(canonical(summary) + b"\n")
    print(canonical(summary).decode())
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
