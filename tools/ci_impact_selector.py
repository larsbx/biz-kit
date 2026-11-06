#!/usr/bin/env python3
"""Conservative read-only Biz-kit CI impact planner.

This is NOT a replacement for required checks or a license to skip a test.
It proposes candidates and records why a change requires broad coverage.
Unknown inputs cause full fallback; invalid repository/diff evidence fails.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import defaultdict, deque
from pathlib import Path, PurePosixPath

SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
APP = re.compile(r"\bapp:\s*:([a-z][a-z0-9_]*)")
UMBRELLA_DEP = re.compile(r"\{\s*:([a-z][a-z0-9_]*)\s*,\s*in_umbrella:\s*true\b")
PURE_SOURCE = re.compile(r"apps/([a-z][a-z0-9_]*)/(?:lib|test)/.+\.exs?\Z")
SCHEMA = "biz-kit-ci-impact-plan-v1"
POLICY = "tools/ci_impact_policy.json"
MODES = ("full_fallback", "focused_advisory")


class EvidenceError(ValueError):
    """Invalid revision, policy or diff metadata: never claim a plan passed."""


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
            .encode("utf-8"))


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def valid_sha(sha: str) -> str:
    if not SHA.fullmatch(sha):
        raise EvidenceError("an exact full-length lowercase hexadecimal commit SHA is required")
    return sha


def valid_path(path: str) -> str:
    if (not path or "\\" in path or path.startswith("/")
            or PurePosixPath(path).is_absolute() or
            any(part in ("", ".", "..") for part in path.split("/"))):
        raise EvidenceError("invalid changed file path")
    return path


def read_policy(root: Path) -> dict:
    try:
        policy = json.loads((root / POLICY).read_text(encoding="utf-8"))
    except (ValueError, OSError) as exc:
        raise EvidenceError("missing or unreadable reviewed impact policy") from exc
    if (not isinstance(policy, dict) or policy.get("schema") != "biz-kit-impact-policy-v1"
            or policy.get("authority") != "advisory-no-skip-no-required-check"):
        raise EvidenceError("unrecognized policy authority or schema")
    safe = policy.get("safe_app_roots")
    owners = policy.get("workflow_owners")
    always = policy.get("always_pr_workflows")
    if not (isinstance(safe, list) and safe and all(isinstance(x, str) for x in safe)
            and len(set(safe)) == len(safe) and isinstance(owners, dict) and owners
            and isinstance(always, list) and len(set(always)) == len(always)):
        raise EvidenceError("incomplete policy")
    if not set(safe).issubset({app for apps in owners.values() for app in apps}):
        raise EvidenceError("safe application lacks workflow coverage")
    workflow_names = set(owners) | set(always)
    for name in workflow_names:
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.ya?ml", name):
            raise EvidenceError("malformed workflow name")
        if not (root / ".github" / "workflows" / name).is_file():
            raise EvidenceError("policy names a missing workflow")
    for name, apps in owners.items():
        if (not isinstance(apps, list) or not apps or
                not all(isinstance(a, str) and a in safe for a in apps)):
            raise EvidenceError("invalid workflow ownership map")
    return policy


def umbrella_graph(root: Path) -> dict[str, list[str]]:
    apps_dir = root / "apps"
    if not apps_dir.is_dir():
        raise EvidenceError("missing umbrella apps directory")
    files = sorted(apps_dir.glob("*/mix.exs"))
    if not files:
        raise EvidenceError("no application manifests")
    graph = {}
    for file in files:
        source = file.read_text(encoding="utf-8")
        found = APP.findall(source)
        if len(found) != 1 or found[0] != file.parent.name:
            raise EvidenceError("ambiguous application identity")
        deps = UMBRELLA_DEP.findall(source)
        if source.count("in_umbrella: true") != len(deps):
            raise EvidenceError("unrecognized in_umbrella dependency syntax")
        if len(set(deps)) != len(deps):
            raise EvidenceError("duplicate in_umbrella dependency")
        graph[file.parent.name] = sorted(deps)
    for app, deps in graph.items():
        if app in deps or not set(deps).issubset(graph):
            raise EvidenceError("invalid/missing internal dependency target")
    return graph


def changed_paths(root: Path, base: str, head: str) -> list[str]:
    """Git's NUL-framed name-status includes BOTH sides of renames/copies."""
    valid_sha(base)
    valid_sha(head)
    checkout = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, stderr=subprocess.PIPE
    ).decode("ascii").strip()
    if checkout != head:
        raise EvidenceError("checked-out HEAD differs from reviewed head SHA")
    try:
        raw = subprocess.check_output(
            ["git", "diff", "--no-ext-diff", "--name-status", "-z",
             "--find-renames", f"{base}...{head}", "--"],
            cwd=root, stderr=subprocess.PIPE
        )
    except subprocess.CalledProcessError as exc:
        raise EvidenceError("cannot compute exact-base three-dot diff") from exc
    chunks = raw.split(b"\0")
    if chunks[-1:] != [b""]:
        raise EvidenceError("unterminated Git NUL path record")
    chunks.pop()
    i = 0
    paths = []
    while i < len(chunks):
        try:
            status = chunks[i].decode("ascii")
        except UnicodeError as exc:
            raise EvidenceError("unknown Git status encoding") from exc
        i += 1
        if re.fullmatch(r"[ACMDRTUXB]", status):
            count = 1
        elif re.fullmatch(r"[RC][0-9]{1,3}", status):
            count = 2
        else:
            raise EvidenceError("unsupported Git diff status")
        if i + count > len(chunks):
            raise EvidenceError("incomplete Git diff record")
        for raw_path in chunks[i:i + count]:
            try:
                path = raw_path.decode("utf-8")
            except UnicodeError as exc:
                raise EvidenceError("invalid Git path encoding") from exc
            paths.append(valid_path(path))
        i += count
    return sorted(set(paths))


def dependents(graph: dict[str, list[str]], changed: set[str]) -> list[str]:
    reverse = defaultdict(set)
    for app, deps in graph.items():
        for dep in deps:
            reverse[dep].add(app)
    result = set(changed)
    queue = deque(sorted(changed))
    while queue:
        for consumer in sorted(reverse[queue.popleft()]):
            if consumer not in result:
                result.add(consumer)
                queue.append(consumer)
    return sorted(result)


def plan(root: Path, policy: dict, head: str, event: str,
         paths: list[str] | None = None, force_full: bool = False) -> dict:
    valid_sha(head)
    if event not in ("pull_request", "push", "merge_group", "schedule", "workflow_dispatch"):
        raise EvidenceError("unsupported workflow event")
    if not force_full and event != "pull_request":
        raise EvidenceError("non-PR events require unconditional full proposal")
    if paths is not None:
        paths = sorted(set(valid_path(p) for p in paths))
    selected = set()
    direct = set()
    closure = []
    graph_hash = None
    reasons = []
    mode = "full_fallback"

    if force_full:
        reasons.append(f"unconditional-{event}")
    elif not paths:
        reasons.append("empty-diff-full-fallback")
    else:
        for path in paths:
            match = PURE_SOURCE.fullmatch(path)
            if not match or match[1] not in policy["safe_app_roots"]:
                reasons.append(f"unknown-or-broad-impact:{path}")
            else:
                direct.add(match[1])
        if not reasons:
            try:
                graph = umbrella_graph(root)
                graph_hash = digest(graph)
                if not direct.issubset(graph):
                    raise EvidenceError("unknown application")
                closure = dependents(graph, direct)
                # Application dependencies alone cannot establish full runtime
                # or cross-repository closure. This output stays advisory.
                selected = {
                    name for name, owned in policy["workflow_owners"].items()
                    if set(owned).intersection(closure)
                }
                if not selected:
                    raise EvidenceError("no workflow matched dependent applications")
                mode = "focused_advisory"
                reasons.append("source-derived-umbrella-reverse-dependency-closure")
            except (EvidenceError, OSError) as exc:
                reasons.append(f"incomplete-dependency-evidence:{type(exc).__name__}")
    if mode == "full_fallback":
        selected = set(policy["workflow_owners"])
        direct = set()
        closure = []
    return {
        "schema": SCHEMA,
        "authority": "advisory-no-skip-no-required-check",
        "head_sha": head,
        "event": event,
        "mode": mode,
        "changed_paths": paths if paths is not None else [],
        "direct_apps": sorted(direct),
        "dependent_apps": closure,
        "proposed_focused_workflows": sorted(selected),
        "always_pr_workflows": sorted(policy["always_pr_workflows"]),
        "reason_codes": sorted(set(reasons)),
        "policy_sha256": digest(policy),
        "umbrella_graph_sha256": graph_hash,
        "limitations": [
            "This plan does not execute, disable, authorize skipping, or certify any workflow.",
            "Live required status checks and branch rules are not inspected.",
            "App manifest edges omit runtime/fixture/contract/other-repository links.",
            "Full fallback means a proposal to cover all registered focused workflows, not a full-suite execution receipt.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--base", default=None)
    parser.add_argument("--head", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--force-full", action="store_true")
    parser.add_argument("--output", required=True)
    parser.add_argument("--github-output", default=None)
    args = parser.parse_args()
    try:
        root = Path(args.root).resolve()
        policy = read_policy(root)
        if args.force_full:
            if args.base:
                raise EvidenceError("base SHA not permitted for full-only event")
            valid_sha(args.head)
            checkout = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=root, stderr=subprocess.PIPE
            ).decode("ascii").strip()
            if checkout != args.head:
                raise EvidenceError("full event checked-out head mismatch")
            output = plan(root, policy, args.head, args.event, force_full=True)
        else:
            if not args.base:
                raise EvidenceError("PR requires explicit base SHA")
            paths = changed_paths(root, args.base, args.head)
            output = plan(root, policy, args.head, args.event, paths=paths)
        output["receipt_sha256"] = digest(output)
        rendered = json.dumps(output, sort_keys=True, indent=2) + "\n"
        Path(args.output).write_text(rendered, encoding="utf-8")
        if args.github_output:
            with open(args.github_output, "a", encoding="utf-8") as result:
                result.write("mode=" + output["mode"] + "\n")
                result.write("receipt_sha256=" + output["receipt_sha256"] + "\n")
                result.write("proposed_count=" + str(len(output["proposed_focused_workflows"])) + "\n")
        print(rendered)
        return 0
    except (EvidenceError, OSError, subprocess.CalledProcessError, UnicodeError) as exc:
        print(f"CI IMPACT EVIDENCE BLOCKED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
