"""Finite differential tests of the Python reference and the actual Lean kernel.

This is a local test harness. A caller-supplied ``trusted`` flag is a model
assumption; this interface is not a public verification authority. Successful
comparison is evidence for these finite traces, not a refinement proof.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import itertools
import json
from pathlib import Path
import shlex
import subprocess
import sys

from .codec import loads, replay


@dataclass(frozen=True)
class Case:
    name: str
    scope: str
    request: dict


def binding(**changes):
    return {"target": 1, "input": 2, "environment": 3, "policy": 4, **changes}


def candidate(**changes):
    return {"worker": 10, "generation": 1, "binding": binding(), "artifact": 7,
            "submittedAt": 1, "leaseExpires": 3, **changes}


def reward_state(**changes):
    return {"now": 0, "generation": 0, "owner": 10, "expires": 0,
            "phase": "open", "candidate": None, "payouts": 0,
            "funder": 7, "escrow": 5, "balanceA": 0, "balanceB": 0, **changes}


def reward_request(actions, state=None, config=None):
    return {"kind": "reward", "config": config or {
        "expected": binding(), "reward": 5, "workerA": 10, "workerB": 20},
        "state": reward_state() if state is None else state, "actions": actions}


def reservation_request(actions, **state):
    return {"kind": "reservation", "state": {
        "phase": "idle", "available": 10, "held": 0, "spent": 0, **state},
        "actions": actions}


def action(name, **fields):
    return {"type": name, **fields}


def evidence_mutations(c):
    """Every field of the committed candidate, including its four bindings."""
    for field in ("worker", "generation", "artifact", "submittedAt", "leaseExpires"):
        yield field, {**c, field: c[field] + 1}
    for field in ("target", "input", "environment", "policy"):
        yield "binding-" + field, {**c, "binding": {**c["binding"], field: c["binding"][field] + 1}}


def corpus():
    """Reachable scenarios plus explicitly labelled, possibly unreachable probes.

    Probes compare guard behavior over supplied states. They are not evidence
    that the supplied state is reachable from the commissioned initial state.
    """
    cases = []

    def add(name, request, scope="reachable-sequence"):
        cases.append(Case(name, scope, request))

    submitted = candidate(submittedAt=0, leaseExpires=2)
    add("reward-delayed-verifier-and-retry", reward_request([
        action("lease", worker=10, deadline=2),
        action("submit", worker=10, generation=1, binding=binding(), artifact=7),
        action("tick", delta=100), action("accept", trusted=True, evidence=submitted),
        action("accept", trusted=True, evidence=submitted),
        action("lease", worker=20, deadline=200),
        action("submit", worker=20, generation=1, binding=binding(), artifact=8),
    ]))
    newer = candidate(worker=20, generation=2, submittedAt=2, leaseExpires=4)
    add("reward-stale-lease-and-second-worker", reward_request([
        action("lease", worker=10, deadline=2), action("tick", delta=2),
        action("submit", worker=10, generation=1, binding=binding(), artifact=7),
        action("lease", worker=20, deadline=4),
        action("submit", worker=10, generation=1, binding=binding(), artifact=7),
        action("submit", worker=20, generation=1, binding=binding(), artifact=7),
        action("submit", worker=20, generation=2, binding=binding(), artifact=7),
        action("accept", trusted=True, evidence=newer),
        action("accept", trusted=True, evidence=newer),
    ]))
    bad_bindings = [binding(**{field: 99}) for field in binding()]
    add("reward-all-binding-and-evidence-fields", reward_request([
        action("lease", worker=10, deadline=3), action("tick", delta=1),
        *[action("submit", worker=10, generation=1, binding=b, artifact=7) for b in bad_bindings],
        action("submit", worker=10, generation=1, binding=binding(), artifact=7),
        action("accept", trusted=False, evidence=candidate()),
        *[action("accept", trusted=True, evidence=c) for _, c in evidence_mutations(candidate())],
        action("tick", delta=1000), action("accept", trusted=True, evidence=candidate()),
    ]))
    add("reservation-cancel-running-and-confirm-stop", reservation_request([
        action("reserve", cap=6), action("start"), action("cancel"),
        action("settle", cost=3), action("stop", trusted=False),
        action("settle", cost=0), action("stop", trusted=True),
        action("settle", cost=7), action("settle", cost=3),
        action("settle", cost=3), action("reserve", cap=1),
    ]))
    add("reservation-cancel-before-start", reservation_request([
        action("reserve", cap=6), action("cancel"), action("start"),
        action("settle", cost=0), action("settle", cost=0),
    ]))
    for cap in (0, 10):
        add(f"reservation-full-charge-{cap}", reservation_request([
            action("reserve", cap=cap), action("start"),
            action("stop", trusted=True), action("settle", cost=cap),
        ]))
    huge = 2 ** 100 + 317
    huge_binding = dict(target=huge, input=huge + 1, environment=huge + 2, policy=huge + 3)
    huge_config = dict(expected=huge_binding, reward=huge, workerA=huge + 4, workerB=huge + 5)
    huge_candidate = dict(worker=huge + 5, generation=1, binding=huge_binding, artifact=huge + 6,
                          submittedAt=huge - 1, leaseExpires=huge)
    add("reward-arbitrary-precision-naturals", reward_request([
        action("lease", worker=huge + 5, deadline=huge),
        action("tick", delta=huge - 1),
        action("submit", worker=huge + 5, generation=1, binding=huge_binding, artifact=huge + 6),
        action("tick", delta=huge), action("accept", trusted=True, evidence=huge_candidate),
    ], reward_state(owner=huge + 4, escrow=huge, funder=huge), huge_config))
    add("reservation-arbitrary-precision-naturals", reservation_request([
        action("reserve", cap=huge), action("start"), action("cancel"),
        action("stop", trusted=True), action("settle", cost=huge - 1),
    ], available=huge + 1))

    phases = ("open", "leased", "submitted", "accepted")
    for phase, now, worker, offset, has_candidate in itertools.product(
            phases, (2, 3), (10, 20, 99), (-1, 0, 1), (False, True)):
        s = reward_state(phase=phase, now=now, generation=1, expires=3,
                         candidate=candidate() if has_candidate else None)
        add(f"lease-{phase}-{now}-{worker}-{offset}-{has_candidate}", reward_request([
            action("lease", worker=worker, deadline=now + offset)], s), "explicit-guard-probe")
    for phase, now, worker, generation, b, has_candidate in itertools.product(
            phases, (2, 3), (10, 20, 99), (0, 1, 2), [binding(), *bad_bindings], (False, True)):
        s = reward_state(phase=phase, now=now, generation=1, expires=3,
                         candidate=candidate() if has_candidate else None)
        add(f"submit-{len(cases)}", reward_request([
            action("submit", worker=worker, generation=generation, binding=b, artifact=7)], s),
            "explicit-guard-probe")
    evidence = [candidate(), *[c for _, c in evidence_mutations(candidate())]]
    for phase, trusted, has_candidate, e, payouts, escrow in itertools.product(
            phases, (False, True), (False, True), evidence, (0, 1), (4, 5, 6)):
        s = reward_state(phase=phase, now=100, generation=1, expires=3,
                         candidate=candidate() if has_candidate else None,
                         payouts=payouts, escrow=escrow)
        add(f"accept-{len(cases)}", reward_request([
            action("accept", trusted=trusted, evidence=e)], s), "explicit-guard-probe")
    # Binding and worker guards still reject a self-consistent but invalid
    # candidate in an explicitly supplied, unreachable submitted state.
    for c in [candidate(worker=99), *[candidate(binding=b) for b in bad_bindings]]:
        add(f"self-consistent-invalid-candidate-{len(cases)}", reward_request([
            action("accept", trusted=True, evidence=c)],
            reward_state(phase="submitted", candidate=c)), "explicit-guard-probe")
    reservation_actions = [*[action("reserve", cap=n) for n in (0, 3, 4)],
                           action("start"), action("cancel"),
                           action("stop", trusted=False), action("stop", trusted=True),
                           *[action("settle", cost=n) for n in (0, 4, 5)]]
    for phase, a in itertools.product(
            ("idle", "reserved", "running", "cancelling", "stopped", "settled"),
            reservation_actions):
        add(f"reservation-guard-{len(cases)}", reservation_request(
            [a], phase=phase, available=3, held=4, spent=2), "explicit-guard-probe")
    return cases


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def compare_outputs(cases, stdout):
    """Reject missing, extra, malformed, mistyped, or different output states."""
    lines = stdout.splitlines()
    if len(lines) != len(cases):
        raise ValueError(f"expected {len(cases)} output lines, received {len(lines)}")
    state_count = 0
    for index, (case, line) in enumerate(zip(cases, lines)):
        actual = loads(line)
        expected = replay(case.request)
        # Canonical JSON preserves the distinction between true, 1, and 1.0.
        if canonical(actual) != canonical(expected):
            raise ValueError(f"trace {index} ({case.name}) differs from reference")
        state_count += len(expected["states"])
    return state_count


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-command", help="Lean JSONL executable and arguments; no shell is used")
    parser.add_argument("--report", type=Path, help="write a machine-readable comparison report")
    parser.add_argument("--emit-corpus", type=Path, help="write input JSONL independently of executing Lean")
    parser.add_argument("--timeout", type=float, default=45, help="child process deadline in seconds")
    args = parser.parse_args(argv)
    if not args.lean_command and not args.emit_corpus:
        parser.error("provide --lean-command or --emit-corpus")
    cases = corpus()
    input_text = "".join(canonical(case.request) + "\n" for case in cases)
    report = {"schema": "formal-research-exchange/conformance/v1", "status": "not-run",
              "scope": "finite sequential differential tests, not a refinement proof",
              "trace_count": len(cases), "action_count": sum(len(c.request["actions"]) for c in cases),
              "reachable_sequences": sum(c.scope == "reachable-sequence" for c in cases),
              "explicit_guard_probes": sum(c.scope == "explicit-guard-probe" for c in cases),
              "input_sha256": hashlib.sha256(input_text.encode()).hexdigest()}
    if args.emit_corpus:
        args.emit_corpus.parent.mkdir(parents=True, exist_ok=True)
        args.emit_corpus.write_text(input_text, encoding="utf-8")
    result_code = 0
    if args.lean_command:
        command = shlex.split(args.lean_command)
        report["command"] = command
        try:
            if not command:
                raise ValueError("empty Lean command")
            result = subprocess.run(command, input=input_text, text=True, capture_output=True,
                                    timeout=args.timeout, check=False)
            if result.returncode:
                raise ValueError(f"Lean process exited {result.returncode}: {result.stderr[-4000:]}")
            report["state_count"] = compare_outputs(cases, result.stdout)
            report["output_sha256"] = hashlib.sha256(result.stdout.encode()).hexdigest()
            report["status"] = "passed"
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            report["status"] = "failed"
            report["error"] = str(exc)
            result_code = 1
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if report["status"] == "passed":
        print(f"CONFORMANCE_PASSED {report['trace_count']} traces; {report['state_count']} states")
    elif report["status"] == "failed":
        print("CONFORMANCE_FAILED " + report["error"], file=sys.stderr)
    else:
        print(f"CORPUS_WRITTEN {report['trace_count']} traces")
    return result_code


if __name__ == "__main__":
    raise SystemExit(main())
