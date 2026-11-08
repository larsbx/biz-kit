#!/usr/bin/env python3
"""Run the mandatory local HTTP/SQLite acceptance suite; no skips can pass."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import sqlite3
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


class RecordedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []

    def addSuccess(self, test):
        super().addSuccess(test)
        self.records.append({"test": test.id(), "status": "passed"})

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.records.append({"test": test.id(), "status": "failed"})

    def addError(self, test, error):
        super().addError(test, error)
        self.records.append({"test": test.id(), "status": "error"})

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.records.append({"test": test.id(), "status": "skipped", "reason": reason})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    os.environ["FRE_ADAPTER_TEST_OUTPUT"] = str(output)
    suite = unittest.defaultTestLoader.loadTestsFromName("adapter_pilot.tests.test_acceptance")
    expected = suite.countTestCases()
    started = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2, resultclass=RecordedResult).run(suite)
    passed = (expected > 0 and result.testsRun == expected and result.wasSuccessful()
              and not result.skipped and not result.expectedFailures and not result.unexpectedSuccesses
              and len(result.records) == expected and all(r["status"] == "passed" for r in result.records))
    summary = {"schema": "research-exchange/adapter-acceptance/v1",
               "status": "passed" if passed else "failed", "expected_tests": expected,
               "tests_run": result.testsRun, "skipped": len(result.skipped), "cases": result.records,
               "finished_at": datetime.now(timezone.utc).isoformat(),
               "duration_seconds": time.monotonic() - started,
               "python": platform.python_version(), "sqlite": sqlite3.sqlite_version,
               "scope": "real loopback HTTP, pinned dual proof replay, fixture credits, SQLite process-crash recovery; not production deployment or power-loss certification"}
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    if not passed:
        print("ADAPTER_ACCEPTANCE_FAILED", flush=True)
        return 1
    print(f"ADAPTER_ACCEPTANCE_PASSED {result.testsRun} tests; 0 skipped", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
