"""Offline, non-authoritative format oracle for a proposed federation candidate.

No networking, signature verification, persistence, admission or effect execution.
Passing this check means only that proposed fields and exact payload bytes agree.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
from pathlib import Path

SCHEMA = "halaqa-federation-candidate/draft-0"
CORPUS = "halaqa-federation-format-vectors/draft-0"
VERDICT = "FORMAT_ONLY_UNVERIFIED"
MAX_WIRE = 8192
MAX_PAYLOAD = 4096
MAX_EPOCH = 2**53 - 1
FIELDS = {
    "schema", "message_id", "halaqa_id", "charter_hash", "epoch", "sender",
    "recipient", "kind", "parents", "payload", "payload_hash",
}
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", re.ASCII)
HASH = re.compile(r"sha256:[0-9a-f]{64}", re.ASCII)


class Refused(ValueError):
    """The proposed format is malformed; no authority verdict is implied."""


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refused("duplicate_key")
        result[key] = value
    return result


def _constant(_value):
    raise Refused("invalid_json")


def _depth(wire):
    depth = 0
    quoted = escaped = False
    for char in wire:
        if quoted:
            if escaped:
                escaped = False
            elif char == 92:
                escaped = True
            elif char == 34:
                quoted = False
        elif char == 34:
            quoted = True
        elif char in (123, 91):
            depth += 1
            if depth > 8:
                raise Refused("invalid_json")
        elif char in (125, 93):
            depth -= 1
            if depth < 0:
                raise Refused("invalid_json")


def decode(wire):
    """Return original payload bytes for offline inspection, never admission."""
    if type(wire) is not bytes or not 1 <= len(wire) <= MAX_WIRE:
        raise Refused("wire_limit")
    _depth(wire)
    try:
        message = json.loads(
            wire.decode("utf-8"), object_pairs_hook=_object, parse_constant=_constant,
        )
    except Refused:
        raise
    except (ValueError, UnicodeError, RecursionError):
        raise Refused("invalid_json") from None
    if type(message) is not dict or set(message) != FIELDS:
        raise Refused("fields")
    if message["schema"] != SCHEMA:
        raise Refused("schema")
    for name in ("message_id", "halaqa_id", "sender", "recipient"):
        value = message[name]
        if type(value) is not str or TOKEN.fullmatch(value) is None:
            raise Refused("identifier")
    for name in ("charter_hash", "payload_hash"):
        value = message[name]
        if type(value) is not str or HASH.fullmatch(value) is None:
            raise Refused("digest_format")
    epoch = message["epoch"]
    if type(epoch) is not int or not 0 <= epoch <= MAX_EPOCH:
        raise Refused("epoch")
    if message["kind"] not in ("proposal", "public_activity"):
        raise Refused("kind")
    parents = message["parents"]
    if type(parents) is not list or len(parents) > 16:
        raise Refused("parents")
    if any(type(p) is not str or HASH.fullmatch(p) is None for p in parents):
        raise Refused("parents")
    if parents != sorted(set(parents)):
        raise Refused("parents")
    encoded = message["payload"]
    if type(encoded) is not str:
        raise Refused("payload_encoding")
    try:
        payload = base64.b64decode(encoded, validate=True)
    except (ValueError, UnicodeError):
        raise Refused("payload_encoding") from None
    if base64.b64encode(payload).decode("ascii") != encoded:
        raise Refused("payload_encoding")
    if not 1 <= len(payload) <= MAX_PAYLOAD:
        raise Refused("payload_limit")
    if message["payload_hash"] != "sha256:" + hashlib.sha256(payload).hexdigest():
        raise Refused("payload_digest")
    return {"verdict": VERDICT, "payload": payload, "message": message}


def check_corpus(path: Path):
    """Check exact raw-wire vectors; corpus errors fail the entire check."""
    corpus = json.loads(path.read_text("utf-8"), object_pairs_hook=_object,
                        parse_constant=_constant)
    if (type(corpus) is not dict or set(corpus) != {"schema", "scope", "vectors"}
            or corpus["schema"] != CORPUS or corpus["scope"] != "offline-format-only"
            or type(corpus["vectors"]) is not list or not corpus["vectors"]):
        raise ValueError("invalid corpus")
    seen = set()
    counts = {VERDICT: 0, "REFUSED_FORMAT": 0}
    for vector in corpus["vectors"]:
        if type(vector) is not dict or set(vector) != {
            "name", "wire_base64", "expected", "payload_base64", "reason",
        }:
            raise ValueError("invalid vector")
        name = vector["name"]
        if type(name) is not str or TOKEN.fullmatch(name) is None or name in seen:
            raise ValueError("invalid or duplicate vector name")
        seen.add(name)
        expected = vector["expected"]
        if type(expected) is not str or expected not in counts:
            raise ValueError("invalid expected verdict")
        wire = base64.b64decode(vector["wire_base64"], validate=True)
        if base64.b64encode(wire).decode("ascii") != vector["wire_base64"]:
            raise ValueError("noncanonical corpus wire encoding")
        try:
            result = decode(wire)
        except Refused as exc:
            if expected != "REFUSED_FORMAT" or vector["reason"] != str(exc):
                raise ValueError(f"{name}: unexpected format refusal: {exc}") from exc
            if vector["payload_base64"] is not None:
                raise ValueError(f"{name}: refused vector cannot have accepted payload")
        else:
            if (expected != VERDICT or vector["reason"] is not None
                    or base64.b64encode(result["payload"]).decode("ascii")
                    != vector["payload_base64"]):
                raise ValueError(f"{name}: unexpected verdict or changed payload bytes")
        counts[expected] += 1
    if not all(counts.values()):
        raise ValueError("both positive and negative vectors are required")
    return {"scope": "offline-format-only", "counts": counts}
