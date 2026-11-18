#!/usr/bin/env python3
"""Require deliberate false proofs and forbidden axioms to fail for the intended reason."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

from check_proofs import parse_axioms
from runtime_identity import file_sha


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean", type=Path, required=True)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    cases_document = json.loads(args.cases.read_text())
    cases = cases_document["cases"] if isinstance(cases_document, dict) else cases_document
    if not isinstance(cases, list) or not cases:
        raise ValueError("negative controls must not be empty")
    ids = [case["id"] for case in cases]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate negative control ids")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for case in cases:
        name = case["id"]
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name) or not case.get("required_pattern"):
            raise ValueError("negative controls need a safe ID and a specific required pattern")
        file = (Path.cwd() / case["file"]).resolve()
        if not file.is_relative_to(Path.cwd().resolve() / "negative"):
            raise ValueError("negative control file escapes the negative directory")
        result = subprocess.run([str(args.lean), str(file)], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=60, check=False)
        log = args.output_dir / f"{name}.log"
        log.write_text(result.stdout)
        reason_present = re.search(case["required_pattern"], result.stdout, re.MULTILINE | re.DOTALL) is not None
        detail = None
        if case["mode"] == "compile_rejection":
            passed = result.returncode == 1 and reason_present
        elif case["mode"] == "axiom_rejection":
            passed = False
            if result.returncode == 0 and reason_present:
                try:
                    parse_axioms(result.stdout, [case["target"]])
                except ValueError as exc:
                    detail = str(exc)
                    passed = detail.startswith("unapproved axioms for ")
        else:
            raise ValueError(f"unknown negative mode: {case['mode']}")
        results.append({"id": name, "mode": case["mode"], "source": case["file"],
                        "status": "passed" if passed else "failed", "exit_code": result.returncode,
                        "required_pattern": case["required_pattern"], "reason_present": reason_present,
                        "detail": detail, "log": log.name, "log_sha256": file_sha(log)})
        print(f"{'EXPECTED_REJECTION' if passed else 'NEGATIVE_CONTROL_FAILED'} {name}", flush=True)
    passed = all(result["status"] == "passed" for result in results)
    summary = {"schema": "formal-research-exchange/lean-negative-controls/v1",
               "status": "passed" if passed else "failed", "count": len(results), "cases": results}
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if passed:
        print(f"LEAN_NEGATIVE_CONTROLS_PASSED {len(results)}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
