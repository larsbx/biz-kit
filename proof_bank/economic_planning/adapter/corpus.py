"""Deterministic, synthetic differential fixtures; no observed economic data.

Named acceptance outcomes are specified separately from either implementation.
Random cases extend coverage but do not make a completeness or refinement claim.
"""
from __future__ import annotations

from copy import deepcopy
import random

FAMILIES = ("dispatch", "environment", "fuel", "commodity", "preciousMetal", "market", "centralBank", "geopolitics")
INSTRUMENTS = ("physical", "spot", "forward", "futures", "policy", "observation")
MODES = ("road", "air", "sea", "rail", "inlandWater", "production", "storage")
MAX_NAT = 2**63 - 1


def base_bundle() -> dict:
    physical = {
        "family": "dispatch", "measure": "physicalQuantity", "subject": "terminal-a",
        "material": "container-slots", "grade": "general", "form": "available",
        "unit": "slot", "currency": "", "location": "terminal-a",
        "instrument": "physical", "maturity": None,
    }
    monetary = {
        "family": "fuel", "measure": "moneyMinorUnits", "subject": "quote-1",
        "material": "transport", "grade": "standard", "form": "delivered",
        "unit": "minor-unit", "currency": "USD", "location": "terminal-a",
        "instrument": "physical", "maturity": None,
    }
    source = {"ref": {"source": "capacity", "revision": "rev-1"}, "key": physical,
              "scope": "business-a", "publishedAt": 99, "receivedAt": 100,
              "effectiveFrom": 110, "effectiveUntil": 140, "origin": "observed",
              "quantity": 10, "payloadDigest": "a" * 64}
    quote = {"ref": {"source": "freight-quote", "revision": "rev-1"}, "key": monetary,
             "scope": "business-a", "publishedAt": 99, "receivedAt": 100,
             "effectiveFrom": 110, "effectiveUntil": 140, "origin": "observed",
             "quantity": 7000, "payloadDigest": "b" * 64}
    key = {"scope": "business-a", "constraintId": "terminal-throughput", "bucket": 120}
    allocation = {"resource": key, "source": source["ref"], "signal": physical,
                  "quantity": 2, "mode": "air"}
    cost = {"source": quote["ref"], "signal": monetary, "atTime": 120,
            "components": ["freight/exposure-a/period-120", "fuel/exposure-a/period-120"],
            "currency": "USD", "minorUnits": 7000}
    result = {
        "manifest": {"scope": "business-a", "issuedAt": 100, "horizonStart": 110,
                     "horizonEnd": 140, "snapshot": "snapshot-1", "model": "model-1",
                     "scenario": "baseline", "seed": 17, "currency": "USD"},
        "sources": [source, quote], "readable": [source["ref"], quote["ref"]],
        "resources": [{"key": key, "value": {"source": source["ref"], "signal": physical, "capacity": 10}}],
        "operationalToken": "host-only-test-token",
        "actions": [
            {"kind": "evidence", "request": {"expectedRef": source["ref"], "expectedKey": physical, "evidence": source}},
            {"kind": "evidence", "request": {"expectedRef": quote["ref"], "expectedKey": monetary, "evidence": quote}},
            {"kind": "allocate", "allocation": allocation},
            {"kind": "cost", "line": cost},
            {"kind": "publish", "claim": "forecast"},
        ],
    }
    # JSON-shaped fixtures deliberately have no shared mutable object aliases.
    # deepcopy preserves aliases, so construct the isolation recursively.
    return _isolate(result)


def _isolate(value):
    if isinstance(value, dict):
        return {key: _isolate(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_isolate(item) for item in value]
    return value


def _evidence(bundle: dict, index: int, **changes) -> None:
    bundle["sources"][index].update(deepcopy(changes))
    bundle["actions"][index]["request"]["evidence"] = deepcopy(bundle["sources"][index])


def _signal(bundle: dict, index: int, field: str, value) -> None:
    bundle["sources"][index]["key"][field] = deepcopy(value)
    evidence = bundle["sources"][index]
    bundle["actions"][index]["request"]["evidence"] = deepcopy(evidence)
    bundle["actions"][index]["request"]["expectedKey"] = deepcopy(evidence["key"])
    if index == 0:
        bundle["resources"][0]["value"]["signal"] = deepcopy(evidence["key"])
        bundle["actions"][2]["allocation"]["signal"] = deepcopy(evidence["key"])
    else:
        bundle["actions"][3]["line"]["signal"] = deepcopy(evidence["key"])


def _capacity(bundle: dict, value) -> None:
    _evidence(bundle, 0, quantity=value)
    bundle["resources"][0]["value"]["capacity"] = value


def _bucket(bundle: dict, value: int) -> None:
    bundle["resources"][0]["key"]["bucket"] = value
    bundle["actions"][2]["allocation"]["resource"]["bucket"] = value


def _ref(bundle: dict, index: int, source: str, revision: str) -> None:
    ref = {"source": source, "revision": revision}
    bundle["sources"][index]["ref"] = deepcopy(ref)
    bundle["readable"][index] = deepcopy(ref)
    bundle["actions"][index]["request"]["expectedRef"] = deepcopy(ref)
    bundle["actions"][index]["request"]["evidence"]["ref"] = deepcopy(ref)
    if index == 0:
        bundle["resources"][0]["value"]["source"] = deepcopy(ref)
        bundle["actions"][2]["allocation"]["source"] = deepcopy(ref)
    else:
        bundle["actions"][3]["line"]["source"] = deepcopy(ref)


def _case_specs() -> list[tuple[str, dict, bool, int | None]]:
    cases = []

    def add(name: str, bundle: dict, reject: int | None = None):
        cases.append((name, bundle, reject is None, reject))

    add("baseline_forecast", base_bundle())
    b = base_bundle(); b["actions"] = []; add("empty_trace", b)
    b = base_bundle(); b["actions"] = [{"kind": "publish", "claim": "scenario"}]; add("empty_publication", b, 0)
    for field in ("publishedAt", "receivedAt"):
        b = base_bundle(); _evidence(b, 0, **{field: 101}); add("late_" + field, b, 0)
        b = base_bundle(); _evidence(b, 0, **{field: 100}); add("exact_issue_" + field, b)
    b = base_bundle(); b["readable"] = b["readable"][1:]; add("denied_read", b, 0)
    b = base_bundle(); _evidence(b, 0, scope="business-b"); add("foreign_evidence_scope", b, 0)
    b = base_bundle(); _evidence(b, 0, effectiveUntil=110); add("empty_effect_interval", b, 0)
    b = base_bundle(); _evidence(b, 0, effectiveUntil=109); add("reversed_effect_interval", b, 0)
    b = base_bundle(); _evidence(b, 0, payloadDigest=""); add("empty_digest", b, 0)
    b = base_bundle(); b["actions"].insert(1, deepcopy(b["actions"][0])); add("repeat_evidence", b, 1)
    b = base_bundle(); b["actions"][0]["request"]["expectedRef"]["revision"] = "rev-2"; add("substituted_expected_revision", b, 0)
    b = base_bundle(); b["actions"][0]["request"]["evidence"]["quantity"] = 999; add("substituted_source_payload", b, 0)
    b = base_bundle(); b["sources"] = b["sources"][1:]; add("missing_source", b, 0)

    replacements = {
        "family": "commodity", "measure": "indicator", "subject": "other-subject",
        "material": "silver", "grade": "fine-999", "form": "bar", "unit": "fine-troy-ounce",
        "currency": "EUR", "location": "other-terminal", "instrument": "futures", "maturity": 180,
    }
    for field, value in replacements.items():
        b = base_bundle(); b["actions"][0]["request"]["expectedKey"][field] = value
        add("evidence_key_" + field, b, 0)
        b = base_bundle(); b["actions"][2]["allocation"]["signal"][field] = value
        add("allocation_key_" + field, b, 2)
        b = base_bundle(); b["actions"][3]["line"]["signal"][field] = value
        add("cost_key_" + field, b, 3)

    for family in FAMILIES:
        b = base_bundle(); _signal(b, 0, "family", family); add("family_" + family, b)
    for instrument in INSTRUMENTS:
        b = base_bundle(); _signal(b, 0, "instrument", instrument)
        if instrument in ("forward", "futures"):
            _signal(b, 0, "maturity", 200)
        add("instrument_" + instrument, b)
    for mode in MODES:
        b = base_bundle(); b["actions"][2]["allocation"]["mode"] = mode; add("mode_" + mode, b)
    for origin in ("observed", "synthetic", "hypothetical"):
        b = base_bundle(); _evidence(b, 0, origin=origin); b["actions"][-1]["claim"] = "scenario"
        add("origin_" + origin + "_scenario", b)
    b = base_bundle(); _signal(b, 0, "measure", "indicator"); b["actions"] = [b["actions"][0], b["actions"][4]]
    add("indicator_evidence", b)

    b = base_bundle(); b["resources"] = []; add("missing_resource", b, 2)
    b = base_bundle(); _capacity(b, None); add("unknown_capacity", b, 2)
    b = base_bundle(); _capacity(b, 0); add("zero_capacity", b, 2)
    b = base_bundle(); _evidence(b, 0, quantity=9); add("invented_capacity", b, 2)
    b = base_bundle(); b["actions"][2]["allocation"]["source"]["revision"] = "rev-2"; add("allocation_revision", b, 2)
    b = base_bundle(); b["resources"][0]["key"]["scope"] = "business-b"; b["actions"][2]["allocation"]["resource"]["scope"] = "business-b"
    add("foreign_resource_scope", b, 2)
    for measure in ("moneyMinorUnits", "indicator"):
        b = base_bundle(); _signal(b, 0, "measure", measure); add("capacity_measure_" + measure, b, 2)
    for quantity, reject in ((0, 2), (10, None), (11, 2)):
        b = base_bundle(); b["actions"][2]["allocation"]["quantity"] = quantity; add("allocation_quantity_" + str(quantity), b, reject)
    for bucket, label, reject in ((109, "before_effect", 2), (110, "effect_start", None), (139, "effect_last", None), (140, "effect_end", 2)):
        b = base_bundle(); b["manifest"]["horizonStart"] = 105; b["manifest"]["horizonEnd"] = 150; _bucket(b, bucket)
        add("allocation_" + label, b, reject)
    b = base_bundle(); b["manifest"]["horizonStart"] = 120; add("allocation_horizon_start", b)
    b = base_bundle(); b["manifest"]["horizonEnd"] = 120; add("allocation_horizon_end", b, 2)
    b = base_bundle(); b["actions"][2]["allocation"]["quantity"] = 6
    other = deepcopy(b["actions"][2]); other["allocation"].update(quantity=5, mode="sea"); b["actions"].insert(3, other)
    add("shared_pool_overbook", b, 3)
    b = base_bundle(); b["actions"][2]["allocation"]["quantity"] = 6
    other = deepcopy(b["actions"][2]); other["allocation"].update(quantity=4, mode="sea"); b["actions"].insert(3, other)
    add("shared_pool_exact", b)
    b = base_bundle(); second = deepcopy(b["resources"][0]); second["key"]["bucket"] = 121; b["resources"].append(second)
    other = deepcopy(b["actions"][2]); other["allocation"]["resource"]["bucket"] = 121; other["allocation"].update(quantity=10, mode="sea")
    b["actions"].insert(3, other); add("independent_atomic_buckets", b)
    b = base_bundle(); _capacity(b, 2**53); b["actions"][2]["allocation"]["quantity"] = 2**53 + 1
    add("integer_rounding_overbook", b, 2)
    for value, label in ((2**53 + 1, "above_float_exact_range"), (MAX_NAT, "max_wire_natural")):
        b = base_bundle(); _capacity(b, value); b["actions"][2]["allocation"]["quantity"] = value; add(label, b)
    b = base_bundle(); _capacity(b, 2**53); b["actions"][2]["allocation"]["quantity"] = 2**53
    other = deepcopy(b["actions"][2]); other["allocation"].update(quantity=1, mode="sea"); b["actions"].insert(3, other)
    add("large_integer_aggregate_overbook", b, 3)

    b = base_bundle(); b["actions"] = [b["actions"][3]]; add("cost_before_evidence", b, 0)
    b = base_bundle(); _evidence(b, 1, quantity=0); b["actions"][3]["line"]["minorUnits"] = 0; add("zero_cost_total", b)
    b = base_bundle(); b["actions"][3]["line"]["minorUnits"] = 7001; add("invented_cost_total", b, 3)
    b = base_bundle(); _evidence(b, 1, quantity=None); add("unknown_cost_total", b, 3)
    b = base_bundle(); _signal(b, 1, "measure", "physicalQuantity"); add("physical_as_money", b, 3)
    b = base_bundle(); _signal(b, 1, "unit", "dollars"); add("noncanonical_money_unit", b, 3)
    b = base_bundle(); _signal(b, 1, "currency", "EUR"); b["actions"][3]["line"]["currency"] = "EUR"; add("mixed_currency", b, 3)
    b = base_bundle(); b["actions"][3]["line"]["components"] = []; add("empty_components", b, 3)
    b = base_bundle(); b["actions"][3]["line"]["components"] = ["fuel", "fuel"]; add("duplicate_components", b, 3)
    b = base_bundle(); other = deepcopy(b["actions"][3]); other["line"]["components"] = ["renamed-same-total"]
    b["actions"].insert(4, other); add("replayed_quote_total", b, 4)
    for overlap in (True, False):
        b = base_bundle(); quote = deepcopy(b["sources"][1]); quote["ref"]["source"] = "insurance-quote"
        b["sources"].append(quote); b["readable"].append(deepcopy(quote["ref"]))
        admission = {"kind": "evidence", "request": {"expectedRef": deepcopy(quote["ref"]), "expectedKey": deepcopy(quote["key"]), "evidence": deepcopy(quote)}}
        other = deepcopy(b["actions"][3]); other["line"]["source"] = deepcopy(quote["ref"])
        other["line"]["components"] = [b["actions"][3]["line"]["components"][1] if overlap else "insurance/exposure-a/period-120"]
        b["actions"].insert(2, admission); b["actions"].insert(5, other)
        add("overlapping_cost_effect" if overlap else "distinct_cost_effect", b, 5 if overlap else None)
    for instant, label, reject in ((109, "before_effect", 3), (110, "effect_start", None), (139, "effect_last", None), (140, "effect_end", 3)):
        b = base_bundle(); b["manifest"]["horizonStart"] = 105; b["manifest"]["horizonEnd"] = 150; b["actions"][3]["line"]["atTime"] = instant
        add("cost_" + label, b, reject)
    b = base_bundle(); b["actions"][3]["line"]["atTime"] = 110; b["sources"][1]["effectiveFrom"] = 100
    b["actions"][1]["request"]["evidence"] = deepcopy(b["sources"][1]); b["manifest"]["horizonStart"] = 111
    add("cost_before_horizon", b, 3)
    b = base_bundle(); b["actions"][3]["line"]["atTime"] = 130; b["manifest"]["horizonEnd"] = 130; add("cost_at_horizon_end", b, 3)

    for origin in ("synthetic", "hypothetical"):
        for index, label in ((0, "physical"), (1, "cost")):
            b = base_bundle(); _evidence(b, index, origin=origin); add(origin + "_" + label + "_forecast", b, 4)
    b = base_bundle(); b["actions"][-1]["claim"] = "observed"; add("derived_observation", b, 4)
    b = base_bundle(); b["actions"][-1]["claim"] = "nowcast"; add("future_nowcast", b, 4)
    b = base_bundle(); b["manifest"]["horizonStart"] = 90; b["actions"][-1]["claim"] = "nowcast"; add("nowcast_contains_issue", b)
    b = base_bundle(); b["manifest"]["horizonStart"] = 100; b["actions"][-1]["claim"] = "nowcast"; add("nowcast_issue_at_start", b)
    b = base_bundle(); b["manifest"]["horizonStart"] = 100; add("forecast_issue_at_start", b, 4)
    b = base_bundle(); b["manifest"].update(horizonStart=90, horizonEnd=100); b["actions"] = [b["actions"][0], {"kind": "publish", "claim": "nowcast"}]
    add("nowcast_issue_at_end", b, 1)
    b = base_bundle(); b["manifest"].update(horizonStart=120, horizonEnd=120); b["actions"] = [b["actions"][0], {"kind": "publish", "claim": "scenario"}]
    add("empty_publication_horizon", b, 1)
    for field in ("scope", "snapshot", "model", "scenario", "currency"):
        b = base_bundle(); b["manifest"][field] = ""
        if field == "scope":
            _evidence(b, 0, scope="")
        b["actions"] = [b["actions"][0], {"kind": "publish", "claim": "scenario"}]
        add("empty_manifest_" + field, b, 1)
    b = base_bundle(); other = deepcopy(b["actions"][2]); other["allocation"].update(quantity=3, mode="sea")
    b["actions"] += [other, {"kind": "publish", "claim": "forecast"}]; add("publication_prefix_frozen", b)
    b = base_bundle(); other = deepcopy(b["actions"][2]); other["allocation"]["quantity"] = 9
    b["actions"] += [other, {"kind": "publish", "claim": "forecast"}]; add("reject_after_publication", b, 5)
    b = base_bundle(); _ref(b, 0, "a:b", "c"); _ref(b, 1, "a", "b:c"); add("structured_reference_identity", b)
    b = base_bundle(); _signal(b, 0, "grade", "純度９９９"); _signal(b, 0, "location", "港口-ø")
    add("unicode_identity_preserved", b)
    return cases


def named_cases() -> list[tuple[str, dict]]:
    return [(name, bundle) for name, bundle, _, _ in _case_specs()]


def golden_expectations() -> dict[str, dict]:
    """Acceptance/rejection is authored in fixtures, not inferred from a reducer."""
    return {name: {"accepted": accepted, "rejectedAt": rejected}
            for name, _, accepted, rejected in _case_specs()}


def randomized_cases(seed: int = 20261111, count: int = 256) -> list[tuple[str, dict]]:
    rng = random.Random(seed)
    cases = []
    for index in range(count):
        b = base_bundle()
        capacity = rng.choice((None, 0, 1, 3, 10, 100, 2**53, 2**53 + 1, MAX_NAT))
        _capacity(b, capacity)
        b["manifest"].update(seed=seed + index, horizonStart=rng.choice((90, 100, 110)), horizonEnd=150)
        _bucket(b, rng.choice((110, 120, 139, 140)))
        _evidence(b, 0, origin=rng.choice(("observed", "observed", "synthetic", "hypothetical")))
        _evidence(b, 1, origin=rng.choice(("observed", "observed", "hypothetical")))
        if rng.randrange(5) == 0:
            _evidence(b, rng.randrange(2), receivedAt=101)
        if rng.randrange(7) == 0:
            b["readable"] = b["readable"][1:]
        actions = deepcopy(b["actions"][:2])
        for step in range(rng.randrange(1, 14)):
            kind = rng.choice(("allocate", "allocate", "allocate", "cost", "publish"))
            if kind == "allocate":
                action = deepcopy(b["actions"][2])
                action["allocation"].update(mode=rng.choice(MODES), quantity=rng.choice((0, 1, 2, 3, 10, 2**53 + 1)))
            elif kind == "cost":
                action = deepcopy(b["actions"][3])
                if rng.randrange(3) == 0:
                    action["line"]["components"] = ["separate-label-" + str(step)]
                if rng.randrange(5) == 0:
                    action["line"]["minorUnits"] += 1
            else:
                action = {"kind": "publish", "claim": rng.choice(("observed", "nowcast", "forecast", "scenario"))}
            actions.append(action)
        actions.append({"kind": "publish", "claim": "scenario"})
        b["actions"] = actions
        cases.append(("seeded_%04d" % index, b))
    return cases


def assert_goldens(results: dict[str, dict]) -> int:
    """Check independently specified outcomes plus exact concrete snapshots."""
    expectations = golden_expectations()
    fixtures = dict(named_cases())
    for name, expected in expectations.items():
        result = results[name]
        if {key: result[key] for key in expected} != expected:
            raise AssertionError("authored golden outcome disagrees: " + name)
        last = expected["rejectedAt"]
        actions = fixtures[name]["actions"]
        if len(result["states"]) != (len(actions) + 1 if last is None else last + 1):
            raise AssertionError("wrong accepted prefix length: " + name)
    base = base_bundle()
    initial = {"evidence": [], "allocations": [], "costs": [], "publications": [],
               "operationalToken": "host-only-test-token"}
    certificate = {"manifest": deepcopy(base["manifest"]), "claim": "forecast",
                   "evidence": deepcopy(base["sources"]),
                   "allocations": [deepcopy(base["actions"][2]["allocation"])],
                   "costs": [deepcopy(base["actions"][3]["line"])]}
    final = {"evidence": deepcopy(certificate["evidence"]), "allocations": deepcopy(certificate["allocations"]),
             "costs": deepcopy(certificate["costs"]), "publications": [certificate],
             "operationalToken": "host-only-test-token"}
    if results["baseline_forecast"]["states"][0] != initial or results["baseline_forecast"]["states"][-1] != final:
        raise AssertionError("concrete baseline state/certificate golden disagrees")
    frozen = results["publication_prefix_frozen"]["states"][-1]
    if frozen["publications"][0] != certificate or len(frozen["publications"][1]["allocations"]) != 2:
        raise AssertionError("previous publication was rewritten")
    if results["above_float_exact_range"]["states"][-1]["allocations"][0]["quantity"] != 9007199254740993:
        raise AssertionError("exact integer quantity was changed")
    if results["unknown_capacity"]["states"][1]["evidence"][0]["quantity"] is not None:
        raise AssertionError("unknown quantity was changed into zero")
    if results["zero_capacity"]["states"][1]["evidence"][0]["quantity"] != 0:
        raise AssertionError("confirmed zero was changed")
    return len(expectations) + 6


def golden_names() -> list[str]:
    return ["outcome_" + name for name in golden_expectations()] + [
        "baseline_initial_state", "baseline_final_certificate", "frozen_publication",
        "exact_large_integer", "unknown_is_null", "zero_is_zero",
    ]
