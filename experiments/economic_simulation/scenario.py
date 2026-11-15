"""Strict synthetic scenario validation; elapsed integer hours and indivisible units."""
from __future__ import annotations
import copy
import hashlib
import json
import math
import re
from datetime import datetime, timedelta, timezone

class ScenarioError(ValueError):
    """Input violates the versioned experiment contract."""

BUSINESS_DEFAULTS = {"response_probability": 1.0, "response_delay_hours": 2, "acceptance_probability": 1.0, "fulfillment_probability": 1.0, "receipt_delay_hours": 0}
REQUEST_DEFAULTS = {"withdraw_at_hour": None, "exchange_offer_id": None, "acceptable_offer_ids": None}
POLICY_DEFAULTS = {"mechanism": "purchase", "cadence_hours": 0, "selection": "first_quote", "max_cycle_length": None, "rematch_rounds": 0, "failure_penalty_minor": 0, "coordination_cost_minor_per_order": 0}
LIMIT_DEFAULTS = {"max_events": 100000, "max_candidate_pairs": 50000, "solver_work_budget": 1000000}
TOKEN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}\Z")
MAX_INTEGER = 2**53 - 1

def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)

def digest(value):
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()

def load_json(path):
    def object_pairs(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ScenarioError("duplicate JSON object key")
            value[key] = item
        return value
    def invalid_constant(_):
        raise ScenarioError("non-finite JSON number")
    with open(path, encoding="utf-8") as source:
        return json.load(source, object_pairs_hook=object_pairs, parse_constant=invalid_constant)

def _object(value, required, defaults, location):
    if not isinstance(value, dict):
        raise ScenarioError(f"{location}: expected object")
    if set(required) - value.keys():
        raise ScenarioError(f"{location}: missing required fields {sorted(set(required) - value.keys())}")
    if value.keys() - set(required) - defaults.keys():
        raise ScenarioError(f"{location}: unknown fields {sorted(value.keys() - set(required) - defaults.keys())}")
    return copy.deepcopy(defaults | value)

def _int(value, location, minimum=0, maximum=MAX_INTEGER):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ScenarioError(f"{location}: expected integer in [{minimum}, {maximum}]")

def _token(value, location):
    if not isinstance(value, str) or not TOKEN.fullmatch(value):
        raise ScenarioError(f"{location}: expected a short identifier token")

def _probability(value, location):
    if type(value) not in (int, float) or not 0 <= value <= 1 or not math.isfinite(value):
        raise ScenarioError(f"{location}: expected a finite probability between zero and one")

def _rows(value, location):
    if not isinstance(value, list):
        raise ScenarioError(f"{location}: expected array")
    return value

def _unique(rows, location):
    ids = [row["id"] for row in rows]
    if len(set(ids)) != len(ids):
        raise ScenarioError(f"{location}: duplicate IDs")
    return {row["id"]: row for row in rows}

def validate_scenario(value):
    required = ("schema_version", "scenario_id", "start_at", "observed_until_hour", "currency", "businesses", "requests", "offers")
    scenario = _object(value, required, {"description": "", "annual_membership_fee_minor": 25000, "policy": {}, "shocks": [], "limits": {}}, "scenario")
    if scenario["schema_version"] != "1.0":
        raise ScenarioError("unsupported scenario schema_version")
    _token(scenario["scenario_id"], "scenario_id")
    if not isinstance(scenario["description"], str) or len(scenario["description"]) > 4096:
        raise ScenarioError("description: expected text of at most 4096 characters")
    _int(scenario["observed_until_hour"], "observed_until_hour")
    _int(scenario["annual_membership_fee_minor"], "annual_membership_fee_minor")
    if not isinstance(scenario["currency"], str) or not re.fullmatch(r"[A-Z]{3}", scenario["currency"]):
        raise ScenarioError("currency: expected a three-letter uppercase currency code")
    try:
        start = datetime.strptime(scenario["start_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if start.strftime("%Y-%m-%dT%H:%M:%SZ") != scenario["start_at"]:
            raise ValueError
        start + timedelta(hours=scenario["observed_until_hour"])
    except (TypeError, ValueError, OverflowError) as error:
        raise ScenarioError("start_at and observation horizon must fit UTC calendar timestamps") from error
    businesses = []
    for raw in _rows(scenario["businesses"], "businesses"):
        row = _object(raw, ("id",), BUSINESS_DEFAULTS, "business")
        _token(row["id"], "business.id")
        for field in ("response_probability", "acceptance_probability", "fulfillment_probability"):
            _probability(row[field], "business." + field)
        for field in ("response_delay_hours", "receipt_delay_hours"):
            _int(row[field], "business." + field)
        businesses.append(row)
    business_index = _unique(businesses, "businesses")
    offers = []
    offer_fields = ("id", "seller_id", "category", "area", "unit", "quantity", "available_at_hour", "expires_at_hour", "unit_price_minor", "delivery_hours")
    for raw in _rows(scenario["offers"], "offers"):
        row = _object(raw, offer_fields, {}, "offer")
        for field in ("id", "seller_id", "category", "area", "unit"):
            _token(row[field], "offer." + field)
        for field in ("quantity", "available_at_hour", "expires_at_hour", "unit_price_minor", "delivery_hours"):
            _int(row[field], "offer." + field, minimum=1 if field == "quantity" else 0)
        if row["seller_id"] not in business_index:
            raise ScenarioError("offer seller must be a listed business")
        if row["expires_at_hour"] <= row["available_at_hour"]:
            raise ScenarioError("offer must expire after availability")
        if row["unit_price_minor"] * row["quantity"] > MAX_INTEGER:
            raise ScenarioError("offer total exceeds exact JSON integer range")
        offers.append(row)
    offer_index = _unique(offers, "offers")
    requests = []
    request_fields = ("id", "buyer_id", "category", "area", "unit", "quantity", "qualified_at_hour", "due_at_hour", "max_unit_price_minor")
    for raw in _rows(scenario["requests"], "requests"):
        row = _object(raw, request_fields, REQUEST_DEFAULTS, "request")
        for field in ("id", "buyer_id", "category", "area", "unit"):
            _token(row[field], "request." + field)
        for field in ("quantity", "qualified_at_hour", "due_at_hour", "max_unit_price_minor"):
            _int(row[field], "request." + field, minimum=1 if field == "quantity" else 0)
        if row["buyer_id"] not in business_index:
            raise ScenarioError("request buyer must be a listed business")
        if row["due_at_hour"] < row["qualified_at_hour"]:
            raise ScenarioError("request due_at_hour precedes qualification")
        if row["withdraw_at_hour"] is not None:
            _int(row["withdraw_at_hour"], "request.withdraw_at_hour", row["qualified_at_hour"])
        if row["exchange_offer_id"] is not None:
            _token(row["exchange_offer_id"], "request.exchange_offer_id")
            if row["exchange_offer_id"] not in offer_index or offer_index[row["exchange_offer_id"]]["seller_id"] != row["buyer_id"]:
                raise ScenarioError("exchange offer must be owned by the requesting business")
        if row["acceptable_offer_ids"] is not None:
            ids = _rows(row["acceptable_offer_ids"], "request.acceptable_offer_ids")
            for identifier in ids:
                _token(identifier, "request.acceptable_offer_ids")
                if identifier not in offer_index:
                    raise ScenarioError("acceptable_offer_ids references an unknown offer")
            if len(ids) != len(set(ids)):
                raise ScenarioError("duplicate acceptable_offer_ids")
            row["acceptable_offer_ids"] = sorted(ids)
        requests.append(row)
    _unique(requests, "requests")
    linked = [r["exchange_offer_id"] for r in requests if r["exchange_offer_id"] is not None]
    if len(linked) != len(set(linked)):
        raise ScenarioError("barter intents must reference distinct supply lots; shared stock is not separate inventory")
    policy = _object(scenario["policy"], (), POLICY_DEFAULTS, "policy")
    if policy["mechanism"] not in ("purchase", "barter"):
        raise ScenarioError("policy.mechanism must be purchase or barter")
    if policy["selection"] not in ("first_quote", "lowest_cost", "reliability_adjusted"):
        raise ScenarioError("unknown procurement selection policy")
    for field in ("cadence_hours", "failure_penalty_minor", "coordination_cost_minor_per_order"):
        _int(policy[field], "policy." + field)
    _int(policy["rematch_rounds"], "policy.rematch_rounds", maximum=10)
    if policy["max_cycle_length"] is not None:
        _int(policy["max_cycle_length"], "policy.max_cycle_length", minimum=2)
    if policy["mechanism"] == "barter" and any(r["exchange_offer_id"] is None for r in requests):
        raise ScenarioError("each barter request requires its own exchange_offer_id")
    shocks = []
    for raw in _rows(scenario["shocks"], "shocks"):
        if not isinstance(raw, dict):
            raise ScenarioError("shock: expected object")
        if raw.get("kind") == "business_exit":
            row = _object(raw, ("kind", "business_id", "at_hour"), {}, "business_exit")
            if not isinstance(row["business_id"], str) or row["business_id"] not in business_index:
                raise ScenarioError("business_exit references an unknown business")
            _int(row["at_hour"], "business_exit.at_hour")
        elif raw.get("kind") == "carrier_outage":
            row = _object(raw, ("kind", "area", "starts_at_hour", "ends_at_hour"), {}, "carrier_outage")
            _token(row["area"], "carrier_outage.area")
            _int(row["starts_at_hour"], "carrier_outage.starts_at_hour")
            _int(row["ends_at_hour"], "carrier_outage.ends_at_hour", row["starts_at_hour"] + 1)
        else:
            raise ScenarioError("unknown shock kind")
        shocks.append(row)
    limits = _object(scenario["limits"], (), LIMIT_DEFAULTS, "limits")
    for field, limit in limits.items():
        _int(limit, "limits." + field, minimum=1)
    hours = [r["due_at_hour"] for r in requests] + [o["expires_at_hour"] for o in offers]
    try:
        if hours:
            start + timedelta(hours=max(hours))
    except (OverflowError, ValueError) as error:
        raise ScenarioError("future deadlines must fit UTC calendar timestamps") from error
    scenario.update(businesses=sorted(businesses, key=lambda r:r["id"]), requests=sorted(requests, key=lambda r:r["id"]), offers=sorted(offers, key=lambda r:r["id"]), policy=policy, limits=limits, shocks=sorted(shocks,key=canonical_json))
    return scenario

