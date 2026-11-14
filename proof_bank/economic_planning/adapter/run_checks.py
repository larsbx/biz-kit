#!/usr/bin/env python3
"""Run the committed offline boundary inventory and actual Lean comparisons."""
from __future__ import annotations

import argparse
import importlib
import json
import os
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
PACKAGE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGE))

from adapter import corpus, differential  # noqa: E402


def tests_in(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from tests_in(test)
        else:
            yield test


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    repo = PACKAGE.parents[1]
    if output == repo or output.is_relative_to(repo):
        parser.error("write adapter evidence outside the repository")
    output.mkdir(parents=True, exist_ok=False)
    registry = json.loads((PACKAGE / "adapter/checks.json").read_text())
    report = {"schema": "biz-kit/economic-planning/adapter-verification-v1", "status": "running"}
    try:
        tests = importlib.import_module("adapter.test_adversarial")
        suite = unittest.defaultTestLoader.loadTestsFromModule(tests)
        names = [test.id().removeprefix("adapter.test_adversarial.") for test in tests_in(suite)]
        if not names or names != registry["boundary_tests"]:
            raise ValueError("adversarial test inventory does not match committed contract")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        report.update(boundary_tests=names, boundary_test_count=result.testsRun,
                      skipped_test_count=len(result.skipped))
        if not result.wasSuccessful() or result.skipped or result.testsRun != len(names):
            raise ValueError("boundary acceptance tests did not all execute successfully")
        if [name for name, _ in corpus.named_cases()] != registry["named_cases"]:
            raise ValueError("named differential corpus inventory changed")
        if corpus.golden_names() != registry["goldens"]:
            raise ValueError("independent golden inventory changed")
        if differential.mutation_controls() != registry["controls"]:
            raise ValueError("deliberate mutation inventory changed")
        env = dict(os.environ, LEAN_PATH=str(args.build.resolve(strict=True)))
        report["differential"] = differential.run(
            [str(args.lean.resolve(strict=True)), "--run", "Oracle.lean"],
            cwd=str(PACKAGE / "lean"), env=env, seed=registry["seed"],
            count=registry["random_cases"], evidence_dir=output / "oracle",
        )
        report["status"] = "passed"
        print("ECONOMIC_PLANNING_ADAPTER_PASSED", flush=True)
        return 0
    except Exception as exc:
        report.update(status="failed", error=str(exc))
        raise
    finally:
        (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
