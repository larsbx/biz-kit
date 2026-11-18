"""Offline reference implementation of the EconomicPlanning transition semantics.

This module consumes a normalized, validated *internal* bundle. It is not a JSON
or authorization boundary. In particular, ``readable`` and the frozen source and
resource tables must come from the host adapter, never from a caller request.
The independent Lean oracle supplies executable comparison evidence; this file
does not claim a machine-checked refinement theorem.
"""
from __future__ import annotations

from copy import deepcopy


def _initial(token: str) -> dict:
    return {"evidence": [], "allocations": [], "costs": [], "publications": [],
            "operationalToken": token}


def _source(bundle: dict, reference: dict) -> dict | None:
    return next((entry for entry in bundle["sources"] if entry["ref"] == reference), None)


def _resource(bundle: dict, key: dict) -> dict | None:
    return next((entry["value"] for entry in bundle["resources"] if entry["key"] == key), None)


def _used(state: dict, allocation: dict) -> int:
    return sum(previous["quantity"] for previous in state["allocations"]
               if previous["resource"] == allocation["resource"])


def _evidence_allowed(bundle: dict, state: dict, request: dict) -> bool:
    evidence = request["evidence"]
    ref = request["expectedRef"]
    issued = bundle["manifest"]["issuedAt"]
    return (
        ref == evidence["ref"]
        and request["expectedKey"] == evidence["key"]
        and _source(bundle, ref) == evidence
        and ref in bundle["readable"]
        and evidence["scope"] == bundle["manifest"]["scope"]
        and evidence["publishedAt"] <= issued
        and evidence["receivedAt"] <= issued
        and evidence["effectiveFrom"] < evidence["effectiveUntil"]
        and evidence["payloadDigest"] != ""
        and all(evidence["ref"] != item["ref"] for item in state["evidence"])
    )


def _allocation_allowed(bundle: dict, state: dict, allocation: dict) -> bool:
    resource = _resource(bundle, allocation["resource"])
    if resource is None or resource["capacity"] is None:
        return False
    bucket = allocation["resource"]["bucket"]
    manifest = bundle["manifest"]
    linked = any(
        evidence["ref"] == resource["source"]
        and evidence["key"] == resource["signal"]
        and evidence["quantity"] == resource["capacity"]
        and evidence["effectiveFrom"] <= bucket < evidence["effectiveUntil"]
        and evidence["key"]["measure"] == "physicalQuantity"
        for evidence in state["evidence"]
    )
    return (
        allocation["resource"]["scope"] == manifest["scope"]
        and allocation["source"] == resource["source"]
        and allocation["signal"] == resource["signal"]
        and linked
        and manifest["horizonStart"] <= bucket < manifest["horizonEnd"]
        and allocation["quantity"] > 0
        and _used(state, allocation) + allocation["quantity"] <= resource["capacity"]
    )


def _cost_allowed(bundle: dict, state: dict, line: dict) -> bool:
    manifest = bundle["manifest"]
    components = line["components"]
    covered = [component for prior in state["costs"] for component in prior["components"]]
    linked = any(
        evidence["ref"] == line["source"]
        and evidence["key"] == line["signal"]
        and evidence["quantity"] == line["minorUnits"]
        and evidence["key"]["currency"] == line["currency"]
        and evidence["effectiveFrom"] <= line["atTime"] < evidence["effectiveUntil"]
        and evidence["key"]["measure"] == "moneyMinorUnits"
        and evidence["key"]["unit"] == "minor-unit"
        for evidence in state["evidence"]
    )
    return (
        line["currency"] == manifest["currency"]
        and bool(components)
        and len(set(components)) == len(components)
        and all(component not in covered for component in components)
        and linked
        and manifest["horizonStart"] <= line["atTime"] < manifest["horizonEnd"]
        and all(line["source"] != item["source"] for item in state["costs"])
    )


def _publication_allowed(bundle: dict, state: dict, claim: str) -> bool:
    manifest = bundle["manifest"]
    horizon = (
        claim == "scenario"
        or (claim == "nowcast" and manifest["horizonStart"] <= manifest["issuedAt"] < manifest["horizonEnd"])
        or (claim == "forecast" and manifest["issuedAt"] < manifest["horizonStart"])
    )
    return (
        bool(state["evidence"])
        and claim != "observed"
        and (all(evidence["origin"] == "observed" for evidence in state["evidence"]) or claim == "scenario")
        and manifest["horizonStart"] < manifest["horizonEnd"]
        and all(manifest[field] != "" for field in ("scope", "snapshot", "model", "scenario", "currency"))
        and horizon
    )


def _step(bundle: dict, state: dict, action: dict) -> dict | None:
    kind = action["kind"]
    if kind == "evidence":
        if not _evidence_allowed(bundle, state, action["request"]):
            return None
        next_state = deepcopy(state)
        next_state["evidence"].append(deepcopy(action["request"]["evidence"]))
    elif kind == "allocate":
        if not _allocation_allowed(bundle, state, action["allocation"]):
            return None
        next_state = deepcopy(state)
        next_state["allocations"].append(deepcopy(action["allocation"]))
    elif kind == "cost":
        if not _cost_allowed(bundle, state, action["line"]):
            return None
        next_state = deepcopy(state)
        next_state["costs"].append(deepcopy(action["line"]))
    elif kind == "publish":
        if not _publication_allowed(bundle, state, action["claim"]):
            return None
        next_state = deepcopy(state)
        certificate = deepcopy({"manifest": bundle["manifest"], "claim": action["claim"],
                                "evidence": state["evidence"], "allocations": state["allocations"],
                                "costs": state["costs"]})
        next_state["publications"].append(certificate)
    else:
        raise ValueError("unknown internal action kind; validate the request before replay")
    return next_state


def replay(bundle: dict) -> dict:
    """Replay only from ``initial``; retain diagnostics, never accept prior state.

    Prefix states are private differential diagnostics. The public host boundary
    returns a certificate only after the whole request succeeds, not these
    partially accepted states. Every result owns independent copies of its data.
    """
    state = _initial(bundle["operationalToken"])
    states = [deepcopy(state)]
    for index, action in enumerate(bundle["actions"]):
        next_state = _step(bundle, state, action)
        if next_state is None:
            return {"accepted": False, "rejectedAt": index, "states": states}
        state = next_state
        states.append(deepcopy(state))
    return {"accepted": True, "rejectedAt": None, "states": states}


def replay_final(bundle: dict) -> dict:
    """Replay without retaining prefix history, for the bounded host boundary.

    A rejected state is internal diagnostics only; the boundary must refuse the
    entire request. The final result owns its data and never borrows caller state.
    """
    state = _initial(bundle["operationalToken"])
    for index, action in enumerate(bundle["actions"]):
        next_state = _step(bundle, state, action)
        if next_state is None:
            return {"accepted": False, "rejectedAt": index, "state": state}
        state = next_state
    return {"accepted": True, "rejectedAt": None, "state": state}
