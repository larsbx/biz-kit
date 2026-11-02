#!/usr/bin/env python3
"""Read-only, conservative inventory of GitHub Actions workflow triggers.

This is an advisory *coverage inventory*, not an acceptance gate, YAML compiler,
or selector. Unsupported trigger syntax is reported as unknown, never as proof
that a particular event is absent. It runs with Python's standard library.
"""
from __future__ import annotations

import argparse
import ast
import json
import re
from pathlib import Path

WORKFLOW_SUFFIXES = {".yml", ".yaml"}
EVENT_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
KEY_VALUE = re.compile(r"(?P<indent> *)(?P<key>[A-Za-z_][A-Za-z0-9_-]*):(?P<value>.*)")
SEQUENCE = re.compile(r"^\s*-\s+(.+?)\s*$")


def strip_scalar(value: str) -> str:
    return value.strip().strip("'\"")


def inspect_workflow(path: Path) -> dict:
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines()
    # The 'on' key must be literal top-level YAML, not a nested step.
    indices = [i for i, line in enumerate(lines) if re.fullmatch(r"on:\s*(?:#.*)?", line)]
    if len(indices) != 1:
        return {
            "workflow": path.name, "status": "unknown",
            "reason": "missing or unsupported literal top-level on: block",
        }
    start = indices[0]
    end = next((i for i in range(start + 1, len(lines))
                if lines[i] and not lines[i].startswith((" ", "#"))
                and re.match(r"[\w-]+:", lines[i])), len(lines))
    block = lines[start + 1:end]
    events: list[str] = []
    current_event = None
    current_field = None
    paths: list[str] = []
    has_filter = False
    unknown = []
    for line in block:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = KEY_VALUE.fullmatch(line)
        if match:
            depth = len(match["indent"])
            key = match["key"]
            value = match["value"].strip()
            if depth == 2:
                if value and not value.startswith("#"):
                    unknown.append(f"inline event definition: {key}")
                events.append(key)
                current_event = key
                current_field = None
            elif depth == 4:
                current_field = key if current_event == "pull_request" else None
                if current_event == "pull_request" and key in ("paths", "paths-ignore"):
                    has_filter = True
                    if value and not value.startswith("#"):
                        try:
                            inline = ast.literal_eval(value.split(" #", 1)[0])
                            if (not isinstance(inline, list) or not inline or
                                not all(isinstance(item, str) and item for item in inline)):
                                raise ValueError("not a string list")
                            paths.extend(inline)
                        except (ValueError, SyntaxError):
                            unknown.append(f"unsupported inline path filter: {key}")
            elif depth < 2:
                unknown.append("unsupported nesting")
            continue
        item = SEQUENCE.match(line)
        if item and current_event == "pull_request" and current_field in ("paths", "paths-ignore"):
            # A quoted glob is treated as a string; this parser makes no
            # claims about YAML escapes, anchors or explicit tags.
            value = strip_scalar(item.group(1).split(" #", 1)[0])
            if not value or value.startswith(("!", "&", "*", "{", "[")):
                unknown.append("unsupported path filter entry")
            else:
                paths.append(value)
        elif current_event == "pull_request":
            # We do not need to decode nested jobs/steps, but any strange
            # shape under PR triggers invalidates claimed filter coverage.
            unknown.append("unsupported pull_request trigger structure")
    if unknown:
        return {
            "workflow": path.name, "status": "unknown",
            "reason": "; ".join(sorted(set(unknown))),
            "events": sorted(set(events)),
        }
    if has_filter and not paths:
        return {
            "workflow": path.name, "status": "unknown",
            "reason": "empty or unsupported pull_request path filter",
            "events": sorted(set(events)),
        }
    if not events:
        return {"workflow": path.name, "status": "unknown",
                "reason": "no recognized trigger events"}
    return {
        "workflow": path.name, "status": "parsed",
        "events": sorted(set(events)), "pr_path_filtered": has_filter,
        "pr_path_patterns": sorted(set(paths)),
        "jobs_present": bool(re.search(r"^jobs:\s*$", source, re.M)),
        "cancel_in_progress": bool(re.search(r"^\s+cancel-in-progress:\s*", source, re.M)),
        "has_matrix": bool(re.search(r"^\s+matrix:\s*", source, re.M)),
        "declares_services": bool(re.search(r"^\s+services:\s*", source, re.M)),
    }


def inventory(root: Path) -> dict:
    directory = root / ".github" / "workflows"
    if not directory.is_dir():
        raise ValueError("missing .github/workflows directory")
    files = sorted(p for p in directory.iterdir()
                   if p.is_file() and p.suffix in WORKFLOW_SUFFIXES)
    if not files:
        raise ValueError("no GitHub Actions workflows found")
    workflows = [inspect_workflow(path) for path in files]
    parsed = [v for v in workflows if v["status"] == "parsed"]
    unknown = [v for v in workflows if v["status"] == "unknown"]
    return {
        "schema": "biz-kit-ci-workflow-inventory-v1",
        "authority": "advisory-no-acceptance",
        "coverage": "complete" if not unknown else "partial-unknown",
        "workflows": workflows,
        "summary": {
            "total": len(workflows), "parsed": len(parsed), "unknown": len(unknown),
            "pr_triggered": sum("pull_request" in v["events"] for v in parsed),
            "pr_filtered": sum("pull_request" in v["events"] and v["pr_path_filtered"]
                               for v in parsed),
            "pr_unfiltered": sum("pull_request" in v["events"] and not v["pr_path_filtered"]
                                 for v in parsed),
            "merge_group": sum("merge_group" in v["events"] for v in parsed),
        },
        "limits": [
            "This report is not a YAML runtime parser or branch-protection audit.",
            "A triggered or path-filtered workflow does not establish required-check status.",
            "No workload performance, cost or test coverage is inferred from trigger syntax.",
            "Unknown syntax prevents complete inventory coverage.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--output", default=None)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
        data = inventory(Path(args.root).resolve())
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(2, f"CI INVENTORY BLOCKED: {error}\n")
    rendered = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    if args.require_complete and data["coverage"] != "complete":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
