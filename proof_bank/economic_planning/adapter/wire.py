"""Strict, bounded JSON representation for the offline planning boundary."""
from __future__ import annotations

import json
import re
from typing import Any

MAX_NAT = 2**63 - 1
REQUEST_BYTES = 256 * 1024
SNAPSHOT_BYTES = 1024 * 1024
BUNDLE_BYTES = 2 * 1024 * 1024
MAX_DEPTH = 24
MAX_NODES = 50_000
MAX_STRING_BYTES = 512
MAX_ACTIONS = 256
MAX_SOURCES = 128
MAX_RESOURCES = 256
MAX_COMPONENTS = 64
REQUEST_SCHEMA = "biz-kit/economic-planning/request-v1"
SNAPSHOT_SCHEMA = "biz-kit/economic-planning/host-snapshot-v1"
FAMILIES = ("dispatch", "environment", "fuel", "commodity", "preciousMetal", "market", "centralBank", "geopolitics")
MEASURES = ("physicalQuantity", "moneyMinorUnits", "indicator")
INSTRUMENTS = ("physical", "spot", "forward", "futures", "policy", "observation")
ORIGINS = ("observed", "synthetic", "hypothetical")
MODES = ("road", "air", "sea", "rail", "inlandWater", "production", "storage")
CLAIMS = ("observed", "nowcast", "forecast", "scenario")


class SchemaError(ValueError):
    """Input is outside the exact bounded wire contract."""


def _fail(path: str, detail: str) -> None:
    raise SchemaError(f"{path}: {detail}")


def text(value: Any, path: str, *, empty: bool = False) -> str:
    if type(value) is not str or (not empty and not value):
        _fail(path, "expected a nonempty string" if not empty else "expected a string")
    try:
        encoded = value.encode("utf-8", "strict")
    except UnicodeEncodeError:
        _fail(path, "invalid Unicode scalar")
    if len(encoded) > MAX_STRING_BYTES or any(ord(c) < 32 or ord(c) == 127 for c in value):
        _fail(path, "string exceeds bounds or contains a control character")
    return value


def nat(value: Any, path: str) -> int:
    if type(value) is not str or not re.fullmatch(r"0|[1-9][0-9]{0,18}", value):
        _fail(path, "expected canonical decimal natural string")
    result = int(value)
    if result > MAX_NAT:
        _fail(path, "natural exceeds wire bound")
    return result


def optional_nat(value: Any, path: str) -> int | None:
    return None if value is None else nat(value, path)


def obj(value: Any, keys: set[str], path: str) -> dict:
    if type(value) is not dict or set(value) != keys:
        _fail(path, "object must contain exactly the declared fields")
    return value


def array(value: Any, limit: int, path: str) -> list:
    if type(value) is not list or len(value) > limit:
        _fail(path, "expected bounded array")
    return value


def enum(value: Any, choices: tuple[str, ...], path: str) -> str:
    if type(value) is not str or value not in choices:
        _fail(path, "unsupported enum value")
    return value


def currency(value: Any, path: str, *, empty: bool = False) -> str:
    text(value, path, empty=empty)
    if not ((empty and value == "") or re.fullmatch(r"[A-Z]{3}", value)):
        _fail(path, "expected three-letter uppercase currency")
    return value


def _pairs(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            _fail("json", "duplicate decoded object key")
        result[key] = value
    return result


def _no_number(value: str) -> None:
    _fail("json", "numeric literals are forbidden; use canonical decimal strings")


def loads(raw: bytes, *, max_bytes: int = REQUEST_BYTES) -> Any:
    if type(raw) is not bytes or not raw or len(raw) > max_bytes:
        _fail("json", "expected nonempty bounded UTF-8 bytes")
    try:
        source = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        _fail("json", "invalid UTF-8")
    # Bound nesting before invoking the recursive standard-library parser.
    depth = 0
    quoted = escaped = False
    for char in source:
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "[{":
            depth += 1
            if depth > MAX_DEPTH:
                _fail("json", "nesting limit exceeded")
        elif char in "]}":
            depth -= 1
    try:
        value = json.loads(source, object_pairs_hook=_pairs, parse_int=_no_number,
                           parse_float=_no_number, parse_constant=_no_number)
    except (json.JSONDecodeError, RecursionError) as exc:
        raise SchemaError("json: invalid document") from exc
    pending = [value]
    nodes = 0
    while pending:
        item = pending.pop()
        nodes += 1
        if nodes > MAX_NODES:
            _fail("json", "decoded node limit exceeded")
        if type(item) is str:
            text(item, "json string", empty=True)
        elif type(item) is dict:
            pending.extend(item.keys())
            pending.extend(item.values())
        elif type(item) is list:
            pending.extend(item)
    return value


def to_wire(value: Any) -> Any:
    """Encode exact internal values; do not coerce floats or opaque objects."""
    if value is None or type(value) is bool:
        return value
    if type(value) is int:
        if not 0 <= value <= MAX_NAT:
            _fail("encode", "natural outside wire bound")
        return str(value)
    if type(value) is str:
        return text(value, "encode", empty=True)
    if type(value) is list or type(value) is tuple:
        return [to_wire(item) for item in value]
    if type(value) is dict:
        if any(type(key) is not str for key in value):
            _fail("encode", "object keys must be strings")
        return {text(key, "encode key"): to_wire(item) for key, item in value.items()}
    _fail("encode", "unsupported value type")


def dumps(value: Any) -> str:
    return json.dumps(to_wire(value), ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False)


def source_ref(value: Any, path: str) -> dict:
    v = obj(value, {"source", "revision"}, path)
    return {k: text(v[k], f"{path}.{k}") for k in ("source", "revision")}


def ref_identity(value: dict) -> tuple[str, str]:
    return value["source"], value["revision"]


def signal(value: Any, path: str) -> dict:
    v = obj(value, {"family", "measure", "subject", "material", "grade", "form", "unit",
                    "currency", "location", "instrument", "maturity"}, path)
    result = {"family": enum(v["family"], FAMILIES, path + ".family"),
              "measure": enum(v["measure"], MEASURES, path + ".measure"),
              "instrument": enum(v["instrument"], INSTRUMENTS, path + ".instrument"),
              "maturity": optional_nat(v["maturity"], path + ".maturity")}
    for key in ("subject", "material", "grade", "form", "unit", "location"):
        result[key] = text(v[key], path + "." + key, empty=key not in ("subject", "unit"))
    result["currency"] = currency(v["currency"], path + ".currency",
                                  empty=result["measure"] != "moneyMinorUnits")
    if result["measure"] == "moneyMinorUnits" and result["unit"] != "minor-unit":
        _fail(path, "money uses the canonical minor-unit denomination")
    return result


def evidence(value: Any, path: str) -> dict:
    v = obj(value, {"ref", "key", "scope", "publishedAt", "receivedAt", "effectiveFrom",
                    "effectiveUntil", "origin", "quantity", "payloadDigest"}, path)
    result = {"ref": source_ref(v["ref"], path + ".ref"),
              "key": signal(v["key"], path + ".key"),
              "scope": text(v["scope"], path + ".scope"),
              "origin": enum(v["origin"], ORIGINS, path + ".origin"),
              "quantity": optional_nat(v["quantity"], path + ".quantity"),
              "payloadDigest": text(v["payloadDigest"], path + ".payloadDigest")}
    if not re.fullmatch(r"[0-9a-f]{64}", result["payloadDigest"]):
        _fail(path, "payloadDigest must be lowercase SHA-256 text")
    for key in ("publishedAt", "receivedAt", "effectiveFrom", "effectiveUntil"):
        result[key] = nat(v[key], path + "." + key)
    if result["effectiveFrom"] >= result["effectiveUntil"]:
        _fail(path, "effective interval must be nonempty")
    return result


def resource_key(value: Any, path: str) -> dict:
    v = obj(value, {"scope", "constraintId", "bucket"}, path)
    return {"scope": text(v["scope"], path + ".scope"),
            "constraintId": text(v["constraintId"], path + ".constraintId"),
            "bucket": nat(v["bucket"], path + ".bucket")}


def resource_identity(value: dict) -> tuple[str, str, int]:
    return value["scope"], value["constraintId"], value["bucket"]


def resource_entry(value: Any, path: str) -> dict:
    entry = obj(value, {"key", "value"}, path)
    v = obj(entry["value"], {"source", "signal", "capacity"}, path + ".value")
    return {"key": resource_key(entry["key"], path + ".key"),
            "value": {"source": source_ref(v["source"], path + ".value.source"),
                      "signal": signal(v["signal"], path + ".value.signal"),
                      "capacity": optional_nat(v["capacity"], path + ".value.capacity")}}


def allocation(value: Any, path: str) -> dict:
    v = obj(value, {"resource", "source", "signal", "quantity", "mode"}, path)
    return {"resource": resource_key(v["resource"], path + ".resource"),
            "source": source_ref(v["source"], path + ".source"),
            "signal": signal(v["signal"], path + ".signal"),
            "quantity": nat(v["quantity"], path + ".quantity"),
            "mode": enum(v["mode"], MODES, path + ".mode")}


def cost(value: Any, path: str) -> dict:
    v = obj(value, {"source", "signal", "atTime", "components", "currency", "minorUnits"}, path)
    return {"source": source_ref(v["source"], path + ".source"),
            "signal": signal(v["signal"], path + ".signal"),
            "atTime": nat(v["atTime"], path + ".atTime"),
            "components": [text(c, path + ".component") for c in array(v["components"], MAX_COMPONENTS, path + ".components")],
            "currency": currency(v["currency"], path + ".currency"),
            "minorUnits": nat(v["minorUnits"], path + ".minorUnits")}


def action(value: Any, path: str) -> dict:
    if type(value) is not dict:
        _fail(path, "expected action object")
    kind = value.get("kind")
    if kind == "evidence":
        v = obj(value, {"kind", "expectedRef", "expectedKey"}, path)
        return {"kind": kind, "expectedRef": source_ref(v["expectedRef"], path + ".expectedRef"),
                "expectedKey": signal(v["expectedKey"], path + ".expectedKey")}
    if kind == "allocate":
        v = obj(value, {"kind", "allocation"}, path)
        return {"kind": kind, "allocation": allocation(v["allocation"], path + ".allocation")}
    if kind == "cost":
        v = obj(value, {"kind", "line"}, path)
        return {"kind": kind, "line": cost(v["line"], path + ".line")}
    if kind == "publish":
        v = obj(value, {"kind", "claim"}, path)
        return {"kind": kind, "claim": enum(v["claim"], CLAIMS, path + ".claim")}
    _fail(path, "unsupported action kind")


def decode_request(raw: bytes) -> dict:
    v = obj(loads(raw), {"schema", "snapshot", "model", "scenario", "seed", "horizonStart",
                         "horizonEnd", "currency", "actions"}, "request")
    if v["schema"] != REQUEST_SCHEMA:
        _fail("request.schema", "unsupported schema")
    result = {k: text(v[k], "request." + k) for k in ("schema", "snapshot", "model", "scenario")}
    for key in ("seed", "horizonStart", "horizonEnd"):
        result[key] = nat(v[key], "request." + key)
    result["currency"] = currency(v["currency"], "request.currency")
    result["actions"] = [action(a, f"request.actions[{i}]") for i, a in
                         enumerate(array(v["actions"], MAX_ACTIONS, "request.actions"))]
    if result["horizonStart"] >= result["horizonEnd"]:
        _fail("request", "horizon must be nonempty")
    if not result["actions"] or result["actions"][-1]["kind"] != "publish" or sum(
        a["kind"] == "publish" for a in result["actions"]
    ) != 1:
        _fail("request", "exactly one final publication is required")
    return result


def decode_snapshot(raw: bytes) -> dict:
    v = obj(loads(raw, max_bytes=SNAPSHOT_BYTES),
            {"schema", "scope", "issuedAt", "snapshot", "models", "operationalToken", "sources", "resources", "costComponents"}, "snapshot")
    if v["schema"] != SNAPSHOT_SCHEMA:
        _fail("snapshot.schema", "unsupported schema")
    result = {k: text(v[k], "snapshot." + k) for k in ("schema", "scope", "snapshot", "operationalToken")}
    result["issuedAt"] = nat(v["issuedAt"], "snapshot.issuedAt")
    result["models"] = [text(m, "snapshot.model") for m in array(v["models"], 128, "snapshot.models")]
    if not result["models"] or len(set(result["models"])) != len(result["models"]):
        _fail("snapshot.models", "expected nonempty distinct model identifiers")
    result["sources"] = [evidence(e, f"snapshot.sources[{i}]") for i, e in
                         enumerate(array(v["sources"], MAX_SOURCES, "snapshot.sources"))]
    sources = {}
    for item in result["sources"]:
        key = ref_identity(item["ref"])
        if key in sources or item["scope"] != result["scope"]:
            _fail("snapshot.sources", "duplicate identity or foreign scope")
        sources[key] = item
    result["resources"] = [resource_entry(e, f"snapshot.resources[{i}]") for i, e in
                           enumerate(array(v["resources"], MAX_RESOURCES, "snapshot.resources"))]
    identities = set()
    for item in result["resources"]:
        key = resource_identity(item["key"])
        if key in identities or item["key"]["scope"] != result["scope"]:
            _fail("snapshot.resources", "duplicate identity or foreign scope")
        identities.add(key)
        resource = item["value"]
        source = sources.get(ref_identity(resource["source"]))
        if source is None or source["key"] != resource["signal"] or source["quantity"] != resource["capacity"] or source["key"]["measure"] != "physicalQuantity":
            _fail("snapshot.resources", "catalog must match a complete physical source quantity")
    result["costComponents"] = []
    cost_sources = set()
    for index, entry in enumerate(array(v["costComponents"], MAX_SOURCES, "snapshot.costComponents")):
        path = f"snapshot.costComponents[{index}]"
        entry = obj(entry, {"source", "components"}, path)
        ref = source_ref(entry["source"], path + ".source")
        components = [text(c, path + ".component") for c in
                      array(entry["components"], MAX_COMPONENTS, path + ".components")]
        identity = ref_identity(ref)
        source = sources.get(identity)
        if identity in cost_sources or source is None or source["key"]["measure"] != "moneyMinorUnits" or source["quantity"] is None:
            _fail(path, "cost binding requires a distinct known monetary source total")
        if not components or len(set(components)) != len(components):
            _fail(path, "canonical components must be nonempty and distinct")
        cost_sources.add(identity)
        result["costComponents"].append({"source": ref, "components": components})
    return result
