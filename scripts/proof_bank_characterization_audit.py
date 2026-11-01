#!/usr/bin/env python3
"""Fail-closed static Proof Bank catalog audit; NOT an app conformance verifier."""
import argparse
import json
from pathlib import Path

SCHEMA = "biz-kit.proof-bank.characterizations.v1"
STATES = {
    "review_status": "needs_owner_review",
    "test_result": "not_executed",
    "implementation_conformance": "not_established",
    "proof_status": "not_proven",
    "runtime_conformance": "not_established",
}
def audit(root, data):
    problems = []
    if data.get("schema") != SCHEMA:
        problems.append("bad schema")
    records = data.get("records", [])
    if not isinstance(records, list):
        return ["records not a list"]
    ids = [r.get("id") for r in records]
    actual = {p.parent.name for p in (root / "apps").glob("*/mix.exs")} | {"biz-kit"}
    if len(ids) != len(set(ids)) or set(ids) != actual:
        problems.append(f"app drift: missing={sorted(actual-set(ids))}, extra={sorted(set(ids)-actual)}")
    for r in records:
        name = r.get("id", "<missing>")
        if r.get("schema") != "biz-kit.proof-bank.characterization.v1":
            problems.append(f"{name}: bad entry schema")
        if r.get("source_sha") != data.get("source_sha"):
            problems.append(f"{name}: mismatched source SHA")
        for k, expected in STATES.items():
            if r.get(k) != expected:
                problems.append(f"{name}: invalid status {k}")
        if not r.get("intended_purpose") or not r.get("first_formal_obligation"):
            problems.append(f"{name}: incomplete characterization")
        if r.get("first_formal_layer") not in {"L0","L1","L2","L3","L4","L5"}:
            problems.append(f"{name}: unknown verification layer")
        paths = r.get("observed_code_paths", [])
        if not paths:
            problems.append(f"{name}: no code evidence")
        test = r.get("observed_test_path")
        for item in paths + ([test] if test else []):
            if not isinstance(item, str):
                problems.append(f"{name}: invalid path")
                continue
            p = Path(item)
            if p.is_absolute() or ".." in p.parts or not (root / p).is_file():
                problems.append(f"{name}: missing/unsafe evidence path {item}")
    return problems

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    root = Path(args.root).resolve()
    filename = root / "proof_bank/characterizations/v1/catalog.json"
    data = json.loads(filename.read_text(encoding="utf-8"))
    problems = audit(root, data)
    print(json.dumps({
        "source_sha": data.get("source_sha"), "entries": len(data["records"]),
        "static_catalog_consistency": "PASS" if not problems else "FAIL",
        "app_runtime_checks_executed": 0, "formal_claims_proved": 0, "problems": problems
    }, indent=2))
    return 1 if problems else 0
if __name__ == "__main__":
    raise SystemExit(main())
