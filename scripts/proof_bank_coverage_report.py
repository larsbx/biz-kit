#!/usr/bin/env python3
"""Conservative Proof Bank source-coverage inventory.

This reports REVIEW CANDIDATES. It does not run application tests, check
Lean proofs, certify implementation refinement, or grant extensions access.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from proof_bank_characterization_audit import audit


def build(root: Path, catalog: dict) -> dict:
    """Fail closed on drift, missing paths, invalid statuses or changed bytes."""
    errors = audit(root, catalog)
    if errors:
        raise ValueError("source catalog audit failed: " + "; ".join(errors))
    records = catalog["records"]
    rows = []
    for record in sorted(records, key=lambda r: r["id"]):
        # An observed test path is only a lead; it cannot imply execution.
        test = record.get("observed_test_path")
        rows.append({
            "app": record["id"],
            "priority": record.get("priority", "unspecified"),
            "category": record.get("category", "unspecified"),
            "test_file": test,
            "has_test_lead": isinstance(test, str) and bool(test),
            "first_obligation": record["first_formal_obligation"],
            "review_status": record["review_status"],
            "test_status": record["test_result"],
            "proof_status": record["proof_status"],
            "implementation_status": record["implementation_conformance"],
            "runtime_status": record["runtime_conformance"],
        })
    return {
        "schema": "biz-kit.proof-bank.coverage-report.v1",
        "catalog_source_sha": catalog["source_sha"],
        "catalog_entries": len(rows),
        "applications": len(rows) - (1 if any(row["app"] == "biz-kit" for row in rows) else 0),
        "entries_with_test_leads": sum(row["has_test_lead"] for row in rows),
        "entries_without_test_leads": [row["app"] for row in rows if not row["has_test_lead"]],
        "owner_review_pending": sum(row["review_status"] == "needs_owner_review" for row in rows),
        "proofs_established_by_this_report": 0,
        "runtime_conformance_established_by_this_report": 0,
        "rows": rows,
    }


def markdown(report: dict) -> str:
    lines = [
        "# Proof Bank — first-party coverage (source-lead report)",
        "",
        f"Catalog baseline: \`{report['catalog_source_sha']}\`",
        "",
        f"Applications: **{report['applications']}**; platform + apps: **{report['catalog_entries']}**.",
        f"Entries containing a test-file lead: **{report['entries_with_test_leads']}**.",
        f"Owner-review candidates: **{report['owner_review_pending']}**.",
        "",
        "**This is NOT a test-run result, Lean proof, approved requirement, or runtime conformance assertion.**",
        "File existence and pinned bytes are source evidence only.",
        "",
        "| Component | Priority | Test lead | Reviewed | Executed | Proven | Runtime |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for r in report["rows"]:
        # Catalog data is not arbitrary markdown. Quote characters that can
        # alter table structure, and avoid presenting paths as hyperlinks.
        safe = lambda value: str(value).replace("|", "&#124;").replace("\n", " ")
        lines.append(
            f"| \`{safe(r['app'])}\` | {safe(r['priority'])} | "
            f"{safe(r['test_file'] or 'none identified')} | {safe(r['review_status'])} | "
            f"{safe(r['test_status'])} | {safe(r['proof_status'])} | {safe(r['runtime_status'])} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args()
    root = args.root.resolve()
    catalog = json.loads((root / "proof_bank/characterizations/v1/catalog.json").read_text())
    try:
        report = build(root, catalog)
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps(report, indent=2, sort_keys=True) if args.format == "json" else markdown(report), end="" if args.format == "markdown" else "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
