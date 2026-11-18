#!/usr/bin/env python3
"""Run every real local MCP/SQLite/dual-checker acceptance case without skips."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))

from research_exchange_bridge.common import canonical, sha
from adapter_pilot.checker import ControlledChecker

REQUIRED_CASES = frozenset({
    "test_complete_mcp_cycle_reaches_dual_checker_acceptance",
    "test_unicode_receipt_is_canonical_across_python_and_elixir",
    "test_control_characters_and_literal_escapes_keep_canonical_identity",
    "test_valid_other_theorem_is_definitively_rejected",
    "test_stale_and_caller_authority_fields_cannot_be_admitted",
    "test_exact_retries_and_cross_tool_conflicts_are_durable",
    "test_distinct_principals_cannot_read_existing_shared_database_records",
    "test_scopes_and_revocation_are_rechecked_on_actual_mcp_calls",
    "test_pending_dispatch_survives_launcher_restart",
    "test_requester_revoke_regrant_fences_a_real_prepared_check",
    "test_verifier_revoke_regrant_fences_a_real_prepared_check",
    "test_requester_expiry_is_rechecked_after_real_proof_checking",
    "test_two_real_prepared_worker_processes_commit_one_effect",
    "test_before_commit_process_crash_rolls_back_acceptance",
    "test_after_commit_process_crash_preserves_acceptance",
    "test_before_commit_process_crash_rolls_back_rejection",
    "test_after_commit_process_crash_preserves_rejection",
    "test_unavailable_checker_is_inconclusive_and_operator_retry_recovers",
    "test_persisted_identity_and_terminal_history_are_immutable",
    "test_substituted_prepared_bindings_profiles_and_versions_cannot_commit",
})


def cases(suite):
    for entry in suite:
        if isinstance(entry, unittest.TestSuite):
            yield from cases(entry)
        else:
            yield entry.id().rsplit(".", 1)[-1]


def beam_identity(elixir, environment):
    """Both real MCP profiles require the same pinned transport runtime."""
    if not os.access(elixir, os.X_OK):
        raise ValueError("the required Elixir executable is unavailable")
    identity_code = (
        'root = :code.root_dir() |> List.to_string(); '
        'release = :erlang.system_info(:otp_release) |> List.to_string(); '
        'otp = File.read!(Path.join([root, "releases", release, "OTP_VERSION"])) |> String.trim(); '
        'IO.puts(:json.encode(%{"elixir" => System.version(), "otp" => otp}))'
    )
    version = subprocess.run([str(elixir), "-e", identity_code], env=environment,
                             capture_output=True, text=True, timeout=20, check=True)
    beam = json.loads(version.stdout)
    if beam != {"elixir": "1.19.0", "otp": "27.3.4"}:
        raise ValueError("the required Elixir 1.19.0 / OTP 27.3.4 runtime is not selected")
    return beam


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-root", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--elixir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    output = args.output_dir.absolute()
    if output.exists() and any(output.iterdir()):
        raise SystemExit("Acceptance output must be a new or empty directory.")
    output.mkdir(parents=True, exist_ok=True)
    started = time.time_ns()
    summary = {"schema": "research-exchange/durable-runtime-acceptance/v1", "status": "failed",
               "tests": 0, "skips": 0, "scope": "trusted-local-exact-reviewed-export-only"}
    try:
        lean = args.lean_root.resolve(strict=True)
        fixtures = args.fixtures.resolve(strict=True)
        elixir = args.elixir.resolve(strict=True)
        fixture_files = {name: fixtures / name for name in ("profile.json", "expected.export", "alternate.export")}
        fixture_hashes = {name: sha(path.read_bytes()) for name, path in fixture_files.items()}
        checker = ControlledChecker(lean)
        tools = checker.identities()
        environment = dict(os.environ)
        environment["PATH"] = str(elixir.parent) + os.pathsep + environment.get("PATH", "")
        beam = beam_identity(elixir, environment)
        os.environ.update(environment)
        os.environ.update(RESEARCH_EXCHANGE_BRIDGE_LEAN_ROOT=str(lean),
                          RESEARCH_EXCHANGE_BRIDGE_FIXTURES=str(fixtures),
                          RESEARCH_EXCHANGE_BRIDGE_ELIXIR=str(elixir),
                          RESEARCH_EXCHANGE_BRIDGE_OUTPUT=str(output))
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), pattern="test_acceptance.py",
                                                  top_level_dir=str(ROOT.parent))
        discovered = list(cases(suite))
        if not REQUIRED_CASES <= set(discovered) or len(discovered) != len(set(discovered)):
            raise ValueError("required runtime acceptance cases are missing or duplicated")
        summary["required_cases"] = sorted(REQUIRED_CASES)
        with (output / "acceptance.log").open("w") as log:
            result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
        summary.update(tests=result.testsRun, skips=len(result.skipped),
                       failures=len(result.failures), errors=len(result.errors),
                       expected_failures=len(result.expectedFailures), unexpected_successes=len(result.unexpectedSuccesses),
                       fixture_sha256=fixture_hashes, checker_sha256=tools,
                       beam=beam, python=sys.version.split()[0])
        if (result.wasSuccessful() and result.testsRun > 0 and not result.skipped and
                not result.expectedFailures and not result.unexpectedSuccesses):
            summary["status"] = "passed"
        else:
            print((output / "acceptance.log").read_text()[-12_000:], file=sys.stderr)
    except Exception as error:
        summary["preflight_error"] = f"{type(error).__name__}: {error}"
        print(summary["preflight_error"], file=sys.stderr)
    summary["duration_ns"] = time.time_ns() - started
    (output / "summary.json").write_bytes(canonical(summary) + b"\n")
    print(canonical(summary).decode())
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
