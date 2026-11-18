#!/usr/bin/env python3
"""Reproducible, static T0 review queue for Biz-kit tenant boundaries.

This inventory is deliberately NOT an authorization verifier. It records
possible scope boundaries from source text. Reviewers must inspect every
candidate and prove cross-tenant behavior with real PostgreSQL tests.
No dependencies beyond Python's standard library.
"""

import argparse
import json
import re
from collections import Counter
from pathlib import Path

ASH_RESOURCE = re.compile(r"\buse\s+Ash\.Resource\b")
ECTO_SCHEMA = re.compile(r"\buse\s+Ecto\.Schema\b")
ATTRIBUTE_TENANCY = re.compile(
    r"\bmultitenancy\s+do\s+strategy\s+:attribute\s+attribute\s+:tenant_id\b",
    re.S,
)
HAS_TENANCY = re.compile(r"\bmultitenancy\s+do\b")
TENANT_ATTR = re.compile(r"\battribute\s*\(?\s*:tenant_id\b")
REPO_ACCESS = re.compile(
    r"\b(?:[A-Z][A-Za-z0-9_]*\.)*Repo\.(?:all|one|query!?|insert!?|"
    r"insert_all|update!?|update_all|delete!?|delete_all|transaction|get)\s*\("
)
BYPASS = re.compile(r"\bauthorize\?:\s*false\b")
POLICY_BYPASS = re.compile(r"\bbypass\s+always\(\)")

def inspect_source(path: Path, root: Path) -> dict:
    source = path.read_text(encoding="utf-8")
    rel = path.relative_to(root).as_posix()
    ash = bool(ASH_RESOURCE.search(source))
    ecto = bool(ECTO_SCHEMA.search(source))
    has_tenancy = bool(HAS_TENANCY.search(source))
    attribute_tenancy = bool(ATTRIBUTE_TENANCY.search(source))
    if ash:
        kind = (
            "attribute_tenant_ash" if attribute_tenancy
            else "other_tenancy_ash" if has_tenancy
            else "unscoped_ash_review"
        )
    elif ecto:
        kind = "ecto_schema_review"
    else:
        kind = "source_review"

    observations = {}
    for label, pattern in (
        ("raw_repo_calls", REPO_ACCESS),
        ("ash_authorization_bypass", BYPASS),
        ("policy_bypass_always", POLICY_BYPASS),
    ):
        lines = [
            number
            for number, line in enumerate(source.splitlines(), 1)
            if pattern.search(line) and not line.lstrip().startswith("#")
        ]
        if lines:
            observations[label] = lines

    return {
        "path": rel,
        "app": rel.split("/")[1],
        "kind": kind,
        "ash_resource": ash,
        "ecto_schema": ecto,
        "has_tenant_attribute": bool(TENANT_ATTR.search(source)),
        "observations": observations,
    }

def collect(root: Path) -> list:
    paths = sorted((root / "apps").glob("*/lib/**/*.ex"))
    if not paths:
        raise ValueError("no application source found; run from the repository root")
    return [inspect_source(path, root) for path in paths]

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", default="-", help="JSON path or - for stdout")
    parser.add_argument("--revision", default="", help="exact source commit for provenance")
    parser.add_argument("--summary", action="store_true", help="print counts rather than full JSON")
    args = parser.parse_args()
    root = args.root.resolve()
    records = collect(root)
    counts = Counter(row["kind"] for row in records)
    reviewed = [
        row for row in records
        if row["kind"] != "source_review" or row["observations"]
    ]
    report = {
        "schema": "bizkit-tenant-static-review-v1",
        "revision": args.revision,
        "source_root": "apps/*/lib/**/*.ex",
        "warning": "Heuristic source queue, not runtime authorization or RLS proof.",
        "counts": dict(sorted(counts.items())),
        "review_queue": reviewed,
    }
    if args.summary:
        print(json.dumps({
            "revision": args.revision,
            "counts": report["counts"],
            "apps_with_unscoped_ash": dict(sorted(Counter(
                row["app"] for row in reviewed
                if row["kind"] == "unscoped_ash_review"
            ).items())),
        }, indent=2, sort_keys=True))
    else:
        output = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output == "-":
            print(output, end="")
        else:
            dest = Path(args.output)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(output, encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
