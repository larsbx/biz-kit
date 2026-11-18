"""Compare the offline reducer with the actual Lean kernel's JSONL oracle.

The corpus is finite executable evidence. These comparisons do not prove a
universal language/runtime refinement or authenticate any economic source.
Deliberate mutants below modify reviewed reducer source only, never caller data.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

try:
    from . import corpus, reducer, wire
except ImportError:
    import corpus
    import reducer
    import wire


def first_difference(expected, actual, path: str = "result") -> str | None:
    """Compare every field with exact scalar types, including bool versus int."""
    if type(expected) is not type(actual):
        return f"{path}: type {type(actual).__name__}, expected {type(expected).__name__}"
    if type(expected) is dict:
        if set(expected) != set(actual):
            return f"{path}: object fields differ"
        for key in sorted(expected):
            mismatch = first_difference(expected[key], actual[key], path + "." + key)
            if mismatch:
                return mismatch
    elif type(expected) is list:
        if len(expected) != len(actual):
            return f"{path}: length {len(actual)}, expected {len(expected)}"
        for index, (left, right) in enumerate(zip(expected, actual)):
            mismatch = first_difference(left, right, f"{path}[{index}]")
            if mismatch:
                return mismatch
    elif expected != actual:
        return f"{path}: value {str(actual)[:100]!r}, expected {str(expected)[:100]!r}"
    return None


def require_equal(expected, actual, label: str) -> None:
    mismatch = first_difference(expected, actual)
    if mismatch:
        raise AssertionError(label + ": " + mismatch)


def _mutations() -> list[dict]:
    return [
        {
            "name": "split_mode_capacity", "witness": "shared_pool_overbook",
            "before": 'if previous["resource"] == allocation["resource"])',
            "after": 'if previous["resource"] == allocation["resource"] and previous["mode"] == allocation["mode"])',
        },
        {
            "name": "rounded_capacity", "witness": "integer_rounding_overbook",
            "before": '_used(state, allocation) + allocation["quantity"] <= resource["capacity"]',
            "after": 'float(_used(state, allocation) + allocation["quantity"]) <= float(resource["capacity"])',
        },
        {
            "name": "ignored_read_authority", "witness": "denied_read",
            "before": 'and ref in bundle["readable"]',
            "after": 'and True',
        },
        {
            "name": "ignored_receipt_time", "witness": "late_receivedAt",
            "before": 'and evidence["receivedAt"] <= issued',
            "after": 'and True',
        },
        {
            "name": "unbound_source_payload", "witness": "substituted_source_payload",
            "before": 'and _source(bundle, ref) == evidence',
            "after": 'and True',
        },
        {
            "name": "physical_total_as_money", "witness": "physical_as_money",
            "before": 'and evidence["key"]["measure"] == "moneyMinorUnits"',
            "after": 'and True',
        },
        {
            "name": "reused_total_quote", "witness": "replayed_quote_total",
            "before": 'and all(line["source"] != item["source"] for item in state["costs"])',
            "after": 'and True',
        },
        {
            "name": "scenario_downgrade", "witness": "hypothetical_cost_forecast",
            "before": '(all(evidence["origin"] == "observed" for evidence in state["evidence"]) or claim == "scenario")',
            "after": 'True',
        },
        {
            "name": "rewritten_publication", "witness": "publication_prefix_frozen",
            "before": '        next_state["publications"].append(certificate)',
            "after": '        for previous in next_state["publications"]:\n            previous["allocations"] = deepcopy(state["allocations"])\n        next_state["publications"].append(certificate)',
        },
        {
            "name": "skipped_rejection", "witness": "denied_read",
            "path": "prefix",
            "before": '            return {"accepted": False, "rejectedAt": index, "states": states}',
            "after": '            continue',
        },
        {
            "name": "skipped_final_rejection", "witness": "denied_read",
            "path": "final",
            "before": '            return {"accepted": False, "rejectedAt": index, "state": state}',
            "after": '            continue',
        },
    ]


def mutation_controls() -> list[dict[str, str]]:
    return [{"name": mutation["name"], "witness": mutation["witness"], "path": mutation.get("path", "both")}
            for mutation in _mutations()]


def _final(result: dict) -> dict:
    return {"accepted": result["accepted"], "rejectedAt": result["rejectedAt"], "state": result["states"][-1]}


def _run_mutations(fixtures: dict[str, dict], oracle_results: dict[str, dict]) -> list[dict]:
    source_path = Path(reducer.__file__).resolve()
    source = source_path.read_text(encoding="utf-8")
    reports = []
    for mutation in _mutations():
        if source.count(mutation["before"]) != 1:
            raise AssertionError("mutation point must occur exactly once: " + mutation["name"])
        changed = source.replace(mutation["before"], mutation["after"], 1)
        namespace = {"__name__": "planning_deliberate_mutant_" + mutation["name"], "__file__": str(source_path)}
        # The mutated code is fixed, reviewed local source; no submitted text is
        # executed. Compile/import failures do not count as detection evidence.
        exec(compile(changed, str(source_path) + ":mutant:" + mutation["name"], "exec"), namespace)
        witness = mutation["witness"]
        path = mutation.get("path", "both")
        paths = ("prefix", "final") if path == "both" else (path,)
        mismatches = {}
        for target in paths:
            result = namespace["replay" if target == "prefix" else "replay_final"](fixtures[witness])
            actual = wire.to_wire(result)
            expected = oracle_results[witness] if target == "prefix" else _final(oracle_results[witness])
            mismatch = first_difference(expected, actual)
            if mismatch is None:
                raise AssertionError("unsafe candidate escaped the differential comparison: " + mutation["name"] + "." + target)
            # Require the same rejecting comparator used for ordinary differential
            # acceptance, not an independent mutation-only shortcut.
            rejected = False
            try:
                require_equal(expected, actual, mutation["name"] + "." + target)
            except AssertionError:
                rejected = True
            if not rejected:
                raise AssertionError("comparison did not reject mutant: " + mutation["name"] + "." + target)
            mismatches[target] = mismatch
        reports.append({"name": mutation["name"], "witness": witness, "path": path,
                        "mismatch": next(iter(mismatches.values())), "mismatches": mismatches,
                        "mutated_source_sha256": hashlib.sha256(changed.encode()).hexdigest()})
    return reports


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("oracle emitted duplicate JSON key")
        result[key] = value
    return result


def _number(_):
    raise ValueError("oracle emitted a JSON number instead of an exact natural string")


def run(oracle_command: list[str], *, cwd=None, env=None, seed: int = 20261111,
        count: int = 256, evidence_dir=None, timeout: float = 180) -> dict:
    """Run one bounded oracle process and require exact complete output equality."""
    if type(oracle_command) is not list or not oracle_command or any(type(item) is not str for item in oracle_command):
        raise ValueError("oracle command must be a nonempty argument vector")
    if type(count) is not int or not 0 <= count <= 1024 or type(seed) is not int or not 0 <= seed <= corpus.MAX_NAT - count:
        raise ValueError("invalid bounded deterministic corpus parameters")
    named = corpus.named_cases()
    cases = named + corpus.randomized_cases(seed, count)
    names = [name for name, _ in cases]
    if len(set(names)) != len(names):
        raise AssertionError("duplicate differential case name")
    fixtures = dict(cases)
    expected_native = {name: reducer.replay(bundle) for name, bundle in cases}
    golden_count = corpus.assert_goldens(expected_native)
    encoded_input = ("\n".join(wire.dumps(bundle) for _, bundle in cases) + "\n").encode("utf-8")
    evidence = Path(evidence_dir) if evidence_dir is not None else None
    if evidence is not None:
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / "oracle-input.jsonl").write_bytes(encoded_input)
    start = time.monotonic()
    with subprocess.Popen(oracle_command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(encoded_input, timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            if evidence is not None:
                (evidence / "oracle-stdout.jsonl").write_bytes(stdout)
                (evidence / "oracle-stderr.log").write_bytes(stderr)
            raise AssertionError("Lean oracle timeout is not a differential pass")
    if evidence is not None:
        (evidence / "oracle-stdout.jsonl").write_bytes(stdout)
        (evidence / "oracle-stderr.log").write_bytes(stderr)
    if process.returncode != 0:
        raise AssertionError("Lean oracle failed with exit " + str(process.returncode))
    lines = stdout.decode("utf-8", "strict").splitlines()
    if len(lines) != len(cases) or any(not line for line in lines):
        raise AssertionError("Lean oracle result line inventory is incomplete or contains extra output")
    oracle_results = {}
    for (name, bundle), line in zip(cases, lines):
        actual = json.loads(line, object_pairs_hook=_pairs, parse_int=_number,
                            parse_float=_number, parse_constant=_number)
        expected = wire.to_wire(expected_native[name])
        require_equal(expected, actual, name)
        final_actual = wire.to_wire(reducer.replay_final(bundle))
        require_equal(_final(actual), final_actual, name + ".bounded_final_replay")
        oracle_results[name] = actual
    controls = _run_mutations(fixtures, oracle_results)
    return {
        "schema": "biz-kit/economic-planning/differential-v1", "status": "passed",
        "case_names": names, "named_case_names": [name for name, _ in named],
        "seed": seed, "random_case_count": count, "case_count": len(cases),
        "golden_names": corpus.golden_names(), "golden_count": golden_count,
        "controls": controls,
        "full_state_comparisons": sum(len(result["states"]) for result in expected_native.values()),
        "public_final_comparison_count": len(cases),
        "oracle_command": oracle_command, "oracle_exit_code": process.returncode,
        "oracle_seconds": round(time.monotonic() - start, 3),
        "input_sha256": hashlib.sha256(encoded_input).hexdigest(),
        "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
        "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
        "claims": {"finite_differential_evidence": True, "universal_runtime_refinement": False,
                   "source_authentication": False, "forecast_accuracy": False},
    }
