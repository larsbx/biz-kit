#!/usr/bin/env python3
"""Compare concrete runtime transitions with the compiled Lean representation."""
from __future__ import annotations

import argparse
from copy import deepcopy
import itertools
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent))
from research_exchange_bridge.common import canonical, loads, sha
from research_exchange_bridge import model


def base():
    binding = {"contributor": "researcher-λ", "library": "reviewed-lean-fixture", "engine": "lean",
               "source_revision": "a" * 40, "source_snapshot_sha256": "b" * 64,
               "target": "ResearchExchange.Adapter.expected_fixture", "artifact_sha256": "c" * 64,
               "environment_sha256": "d" * 64, "policy_sha256": "e" * 64,
               "core_revision": "f" * 40, "core_source_sha256": "0" * 64, "generation": 1}
    return {"config": {"expected": deepcopy(binding), "profile": "profile1", "verifier": "controlled-verifier", "reward": 1},
            "state": model.initial(binding, 0, 0),
            "identity": {"authenticated": True, "principal": "controlled-verifier", "requester": binding["contributor"]},
            "prepared": {"binding": deepcopy(binding), "profile": "profile1", "version": 0,
                         "authority_epoch": 0, "requester_epoch": 0, "checked": True}, "verdict": "accepted"}


def generated_cases():
    cases = []
    for bits in itertools.product((False, True), repeat=7):
        for verdict in ("accepted", "rejected", "inconclusive"):
            wire = base()
            auth, verifier, requester, version, authority_epoch, requester_epoch, checked = bits
            wire["identity"]["authenticated"] = auth
            wire["state"].update(verifier_enabled=verifier, requester_enabled=requester)
            wire["prepared"].update(version=0 if version else 1, authority_epoch=0 if authority_epoch else 1,
                                    requester_epoch=0 if requester_epoch else 1, checked=checked)
            wire["verdict"] = verdict
            cases.append(("guards-" + "".join(str(int(x)) for x in bits) + "-" + verdict, wire))
    for location in ("prepared", "config"):
        for field in model.BINDING_FIELDS:
            for verdict in ("accepted", "rejected", "inconclusive"):
                wire = base()
                record = wire[location]["binding" if location == "prepared" else "expected"]
                record[field] = record[field] + 1 if field == "generation" else record[field] + "!"
                wire["verdict"] = verdict
                cases.append((f"substitute-{location}-{field}-{verdict}", wire))
    mutations = [("identity", "principal", "other"), ("identity", "requester", "other"),
                 ("prepared", "profile", "other"), ("state", "payouts", 1),
                 ("state", "escrow", 0), ("state", "escrow", 2), ("state", "settlement", True),
                 ("state", "refund_amount", 1), ("state", "phase", "accepted"),
                 ("state", "phase", "rejected"), ("config", "reward", 0)]
    for section, field, value in mutations:
        for verdict in ("accepted", "rejected", "inconclusive"):
            wire = base()
            wire[section][field] = value
            wire["verdict"] = verdict
            cases.append((f"boundary-{section}-{field}-{value}-{verdict}", wire))
    for label, contributor in (("unicode", "باحث-λ-研究者"), ("framing", "a\x00b\u0100c"), ("empty", "")):
        for verdict in ("accepted", "rejected", "inconclusive"):
            wire = base()
            for record in (wire["config"]["expected"], wire["state"]["binding"], wire["prepared"]["binding"]):
                record["contributor"] = contributor
                record["library"] = "tuple:\x00/λ"
                record["generation"] = 17
            wire["identity"]["requester"] = contributor
            wire["verdict"] = verdict
            cases.append((f"encoding-{label}-{verdict}", wire))
    return cases


def observed_cases(directory):
    result = []
    if directory is None:
        return result
    for path in sorted(directory.rglob("*.json")):
        def walk(value):
            if type(value) is dict:
                if type(value.get("state")) is dict and type(value.get("effects")) is list:
                    for effect in value["effects"]:
                        if type(effect.get("wire_json")) is not str:
                            raise ValueError("Committed effect lacks its input wire")
                        result.append(("sqlite:" + path.relative_to(directory).as_posix() + ":" + str(len(result)),
                                       loads(effect["wire_json"]), value))
                for child in value.values():
                    walk(child)
            elif type(value) is list:
                for child in value:
                    walk(child)
        walk(loads(path.read_bytes()))
    return result


def collect_observations(directories):
    observations, counts = [], []
    for index, directory in enumerate(directories):
        cases = observed_cases(directory)
        if not cases:
            raise ValueError("No actual committed SQLite wire observations found in " + str(directory))
        observations.extend((f"profile-{index}:" + name, wire, state) for name, wire, state in cases)
        counts.append({"directory": str(directory), "committed_observations": len(cases)})
    return observations, counts


def validate_observation(observed, wire, result):
    """Compare the actual durable output, not merely two replays of its input."""
    effects = observed["effects"]
    if (len(effects) != 1 or canonical(observed["state"]) != canonical(result["state"]) or
            type(observed["version"]) is not int or observed["version"] != result["state"]["version"] or observed["terminal"] is not True or
            observed["outbox"] != "complete"):
        raise ValueError("Persisted state/effect/outbox differs from the compiled Lean result")
    effect = effects[0]
    if (type(effect["before_version"]) is not int or type(effect["after_version"]) is not int or
            effect["before_version"] != wire["state"]["version"] or effect["after_version"] != observed["version"] or
            effect["kind"] != wire["verdict"] or effect["kind"] != observed["state"]["phase"] or
            canonical(loads(effect["receipt_json"])) != canonical(observed["receipt"])):
        raise ValueError("Durable effect and receipt do not identify the same transition")
    payload = observed["receipt"]["payload"]
    if (type(payload["state_version"]) is not int or type(payload["mathematical_acceptance"]) is not bool or
            payload["state_version"] != observed["version"] or payload["status"] != effect["kind"] or
            payload["mathematical_acceptance"] != (effect["kind"] == "accepted") or
            payload["credit_issuance"] is not False):
        raise ValueError("Terminal receipt authority/version differs from committed state")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-command", type=Path, default=ROOT / "formal/lean/.lake/build/bin/bridge_trace")
    parser.add_argument("--expected-lean-sha256")
    parser.add_argument("--acceptance-evidence", type=Path, action="append", default=[],
                        help="Repeat for each required profile; every directory must contain committed observations")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    cases = [(name, wire, None) for name, wire in generated_cases()]
    observed, observation_sources = collect_observations(args.acceptance_evidence)
    cases.extend(observed)
    source = b"".join(canonical(wire) + b"\n" for _, wire, _ in cases)
    executable = args.lean_command.resolve(strict=True)
    before = sha(executable.read_bytes())
    if args.expected_lean_sha256 and before != args.expected_lean_sha256:
        raise SystemExit("Compiled representation executable differs from the cold proof receipt")
    run = subprocess.run([str(executable)], input=source, capture_output=True, timeout=120, check=False)
    (args.output_dir / "inputs.jsonl").write_bytes(source)
    (args.output_dir / "lean-output.jsonl").write_bytes(run.stdout)
    (args.output_dir / "lean-stderr.log").write_bytes(run.stderr)
    outputs = run.stdout.splitlines()
    if run.returncode != 0 or len(outputs) != len(cases) or sha(executable.read_bytes()) != before:
        raise SystemExit("Compiled representation replay failed or changed")
    comparisons = []
    for (name, wire, observed_state), line in zip(cases, outputs, strict=True):
        actual = loads(line)
        expected = model.decide(wire)
        if canonical(actual) != canonical(expected) or canonical(actual["projected"]) != canonical(actual["core_result"]):
            (args.output_dir / "mismatch.json").write_bytes(canonical({"name": name, "input": wire, "actual": actual, "expected": expected}))
            raise SystemExit("Representation mismatch: " + name)
        if observed_state is not None:
            validate_observation(observed_state, wire, actual)
        comparisons.append({"name": name, "sha256": sha(canonical(actual)), "ready": actual["ready"]})
    summary = {"schema": "research-exchange/bridge-conformance/v1", "status": "passed",
               "generated_cases": len(cases) - len(observed), "observed_commit_cases": len(observed),
               "comparisons": len(cases), "lean_executable_sha256": before,
               "persisted_post_states_compared": len(observed),
               "observation_sources": observation_sources,
               "input_sha256": sha(source), "output_sha256": sha(run.stdout),
               "scope": "finite runtime/compiled-Lean correspondence; SQL and checker truth remain explicit premises"}
    (args.output_dir / "comparisons.json").write_bytes(canonical(comparisons) + b"\n")
    (args.output_dir / "summary.json").write_bytes(canonical(summary) + b"\n")
    print(canonical(summary).decode())


if __name__ == "__main__":
    main()
