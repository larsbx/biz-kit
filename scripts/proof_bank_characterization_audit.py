#!/usr/bin/env python3
"""Fail-closed static Proof Bank catalog audit; NOT an app conformance verifier."""
import argparse
import copy
import datetime
import json
import hashlib
import subprocess
from pathlib import Path

SCHEMA = "biz-kit.proof-bank.characterizations.v1"
STATES = {
    "review_status": "needs_owner_review",
    "test_result": "not_executed",
    "implementation_conformance": "not_established",
    "proof_status": "not_proven",
    "runtime_conformance": "not_established",
}
REFRESH_HINT = (
    "Only pinned bytes changed. Until the next characterization milestone, refresh the pins: "
    "python3 scripts/proof_bank_characterization_audit.py --refresh"
)

def git_blob(path):
    content = path.read_bytes()
    return hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()

def safe_file(root, item):
    p = Path(item)
    return isinstance(item, str) and not p.is_absolute() and ".." not in p.parts and (root / p).is_file()

def refresh(root, data, at_sha, date):
    """Re-pin evidence whose bytes changed, and log it. Touches nothing else:
    drift, missing paths and statuses still fail the audit afterwards."""
    data = copy.deepcopy(data)
    changed = []
    for r in data.get("records", []):
        pins = r.get("evidence_git_blobs")
        if not isinstance(pins, dict):
            continue
        for item, pinned in pins.items():
            if safe_file(root, item) and git_blob(root / item) != pinned:
                pins[item] = git_blob(root / item)
                changed.append(item)
    if changed:
        data.setdefault("evidence_refreshes", []).append(dict(
            at_sha=at_sha, date=date,
            decision="owner: register and refresh; re-characterize at the next milestone",
            registered=[], refreshed_paths=sorted(changed), renamed={},
            meaning="Pinned bytes updated without re-inspection; characterizations still describe source_sha"))
    return data

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
        evidence = r.get("evidence_git_blobs", {})
        expected_paths = set(paths + ([test] if test else []))
        if not isinstance(evidence, dict) or set(evidence) != expected_paths:
            problems.append(f"{name}: missing/extra pinned evidence hashes")
            evidence = {}
        for item in paths + ([test] if test else []):
            if not isinstance(item, str):
                problems.append(f"{name}: invalid path")
                continue
            if not safe_file(root, item):
                problems.append(f"{name}: missing/unsafe evidence path {item}")
            else:
                if git_blob(root / item) != evidence.get(item):
                    problems.append(f"{name}: changed source/test bytes require re-characterization: {item}")
    return problems

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--refresh", action="store_true",
                        help="re-pin changed evidence bytes and log the refresh (owner policy until the next milestone)")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    filename = root / "proof_bank/characterizations/v1/catalog.json"
    data = json.loads(filename.read_text(encoding="utf-8"))
    if args.refresh:
        at_sha = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                                check=True, capture_output=True, text=True).stdout.strip()
        refreshed = refresh(root, data, at_sha, datetime.date.today().isoformat())
        if refreshed != data:
            filename.write_text(json.dumps(refreshed, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        data = refreshed
    problems = audit(root, data)
    print(json.dumps({
        "source_sha": data.get("source_sha"), "entries": len(data["records"]),
        "static_catalog_consistency": "PASS" if not problems else "FAIL",
        "app_runtime_checks_executed": 0, "formal_claims_proved": 0, "problems": problems
    }, indent=2))
    if problems and all("changed source/test bytes" in p for p in problems):
        print(REFRESH_HINT)
    return 1 if problems else 0
if __name__ == "__main__":
    raise SystemExit(main())
