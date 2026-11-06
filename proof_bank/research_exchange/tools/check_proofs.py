#!/usr/bin/env python3
"""Audit every registered theorem and export its actual dependency closure."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from runtime_identity import file_sha

ALLOWED_AXIOMS = {"propext", "Classical.choice", "Quot.sound"}


def registered_targets(path: Path) -> tuple[str, list[str]]:
    registry = json.loads(path.read_text())
    module = registry["module"]
    names = registry["theorems"]
    if not isinstance(names, list) or not names or len(names) != len(set(names)):
        raise ValueError("theorem registry must be nonempty and contain no duplicates")
    for name in [module, *names]:
        if not isinstance(name, str) or not re.fullmatch(r"ResearchExchange(?:\.[A-Za-z_][A-Za-z0-9_]*)*", name):
            raise ValueError(f"invalid registered Lean name: {name!r}")
    return module, names


def parse_axioms(output: str, targets: list[str]) -> dict[str, list[str]]:
    pattern = r"'([^']+)' (?:depends on axioms:\s*\[([^\]]*)\]|does not depend on any axioms)"
    seen: dict[str, list[str]] = {}
    for match in re.finditer(pattern, output):
        name = match.group(1)
        if name in seen:
            raise ValueError(f"duplicate axiom audit result: {name}")
        dependencies = [] if match.group(2) is None else [x.strip() for x in match.group(2).split(",") if x.strip()]
        forbidden = set(dependencies) - ALLOWED_AXIOMS
        if forbidden:
            raise ValueError(f"unapproved axioms for {name}: {sorted(forbidden)}")
        seen[name] = dependencies
    if set(seen) != set(targets):
        raise ValueError(f"incomplete axiom audit; missing={sorted(set(targets) - set(seen))}, extra={sorted(set(seen) - set(targets))}")
    return seen


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["axioms", "export"])
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("--lean", type=Path)
    parser.add_argument("--leanexport", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    module, targets = registered_targets(args.registry)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.operation == "axioms":
        if args.lean is None:
            parser.error("axioms requires --lean")
        audit = Path.cwd() / ".lake/build/ProofAudit.lean"
        audit.parent.mkdir(parents=True, exist_ok=True)
        audit.write_text(f"import {module}\n" + "\n".join(f"#print axioms {name}" for name in targets) + "\n")
        result = subprocess.run([str(args.lean), str(audit)], capture_output=True, text=True, check=False)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="")
        if result.returncode != 0:
            raise ValueError("Lean axiom inspection failed")
        dependencies = parse_axioms(result.stdout, targets)
        report = {"schema": "formal-research-exchange/axiom-audit/v1", "module": module,
                  "theorem_count": len(targets), "allowed_axioms": sorted(ALLOWED_AXIOMS),
                  "dependencies": dependencies, "status": "passed"}
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(f"AXIOM_AUDIT_PASSED {len(targets)} theorems")
    else:
        if args.leanexport is None:
            parser.error("export requires --leanexport")
        with args.output.open("wb") as output:
            result = subprocess.run([str(args.leanexport), module, "--", *targets], stdout=output, check=False)
        if result.returncode != 0 or args.output.stat().st_size == 0:
            args.output.unlink(missing_ok=True)
            raise ValueError("Lean theorem export failed or was empty")
        print(json.dumps({"status": "exported", "theorem_count": len(targets),
                          "bytes": args.output.stat().st_size, "sha256": file_sha(args.output),
                          "file": str(args.output)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
