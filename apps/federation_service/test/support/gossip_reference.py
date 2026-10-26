#!/usr/bin/env python3
"""Test-only wire oracle: Python stdlib + OpenSSL; no application imports or network.

This checks transcripts, signatures and commitments, NOT marketplace admission,
current pins, expiry policy, durable receipt completion or business authority.
The deterministic seeds below are public fixtures and MUST NOT be deployed.
"""

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

AD = "bizkit.marketplace.halaqa-gossip.v1"
SYNC = "bizkit.marketplace.halaqa-catchup.v1"
LEASE = "bizkit.marketplace.halaqa-freshness.v1"
SCOPE = ("halaqa_id", "charter_hash", "epoch")
AD_FIELDS = set(SCOPE) | {"schema", "publisher", "announcement", "payload", "signature"}
SYNC_FIELDS = set(SCOPE) | set("schema kind from to publisher round batch expires announcement signature".split())
LEASE_FIELDS = set(SCOPE) | set("schema actor publisher listing_id activity_id hash sequence issued expires announcement signature".split())
BATCH_FIELDS = SCOPE + tuple("schema from to publisher round entries expires".split())


def canonical(value):
    """UTF-8 key order, no normalization, Jason-compatible control escaping."""
    if isinstance(value, dict):
        if any(type(k) is not str for k in value):
            raise ValueError("non-string key")
        keys = sorted(value, key=lambda k: k.encode("utf-8"))
        return b"{" + b",".join(canonical(k) + b":" + canonical(value[k]) for k in keys) + b"}"
    if isinstance(value, list):
        return b"[" + b",".join(map(canonical, value)) + b"]"
    if type(value) is str:
        # Jason emits uppercase hex for controls without a short escape.
        escaped = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}
        return ('"' + "".join(escaped.get(c, f"\\u{ord(c):04X}" if ord(c) < 32 else c) for c in value) + '"').encode("utf-8")
    if value is None:
        return b"null"
    if type(value) is bool:
        return b"true" if value else b"false"
    if type(value) is int:
        return str(value).encode("ascii")
    raise ValueError("outside canonical subset")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _pairs(pairs):
    result = {}
    for k, v in pairs:
        if k in result:
            raise ValueError("duplicate key")
        result[k] = v
    return result


def decode(wire):
    raw = wire.encode("utf-8") if isinstance(wire, str) else wire
    if len(raw) > 65536:
        raise ValueError("oversize JSON")
    # Bound depth before parsing, ignoring string contents and escaped quotes.
    depth, quoted, escaped = 0, False, False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (123, 91):
            depth += 1
            if depth > 16:
                raise ValueError("JSON depth")
        elif byte in (125, 93):
            depth -= 1
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-JSON number")))
    if not isinstance(value, dict):
        raise ValueError("not an object")
    return value


def topic(scope):
    return hashlib.sha256("\n".join([AD, scope["halaqa_id"], scope["charter_hash"], str(scope["epoch"])]).encode()).hexdigest()


def transcript(message):
    schema = message.get("schema")
    if schema == AD:
        expected = AD_FIELDS
    elif schema == LEASE:
        expected = LEASE_FIELDS
    elif schema == SYNC and message.get("kind") in ("offer", "receipt"):
        expected = SYNC_FIELDS | {"entries" if message["kind"] == "offer" else "journal"}
    else:
        raise ValueError("unknown profile")
    if set(message) != expected:
        raise ValueError("message fields")
    if schema == AD:
        return "\n".join([AD, message["halaqa_id"], message["charter_hash"], str(message["epoch"]),
                          message["publisher"], message["announcement"], message["payload"]]).encode()
    return canonical({k: v for k, v in message.items() if k != "signature"})


def _openssl(args):
    return subprocess.run(["openssl", *args], capture_output=True, check=True, timeout=10).stdout


def public_key(seed):
    with tempfile.TemporaryDirectory() as d:
        key = Path(d) / "test-key.der"
        key.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
        return _openssl(["pkey", "-inform", "DER", "-in", str(key), "-pubout", "-outform", "DER"])[-32:].hex()


def sign(message, seed):
    m = dict(message, signature="")
    with tempfile.TemporaryDirectory() as d:
        key, data = Path(d) / "test-key.der", Path(d) / "message"
        key.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
        data.write_bytes(transcript(m))
        sig = _openssl(["pkeyutl", "-sign", "-rawin", "-keyform", "DER", "-inkey", str(key), "-in", str(data)])
    return dict(m, signature=base64.b64encode(sig).decode())


def verify(wire, expected_public):
    """Expected key is mandatory: a message's self-asserted key is not a pin."""
    m = decode(wire)
    if m["publisher"] != expected_public:
        raise ValueError("wrong expected key")
    public = bytes.fromhex(expected_public)
    sig = base64.b64decode(m["signature"], validate=True)
    if len(public) != 32 or len(sig) != 64:
        raise ValueError("key/signature length")
    with tempfile.TemporaryDirectory() as d:
        key, data, signature = (Path(d) / n for n in ("key.der", "message", "signature"))
        key.write_bytes(bytes.fromhex("302a300506032b6570032100") + public)
        data.write_bytes(transcript(m))
        signature.write_bytes(sig)
        _openssl(["pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER", "-inkey", str(key),
                  "-in", str(data), "-sigfile", str(signature)])
    return m


def check_bundle(bundle):
    if topic(bundle["scope"]) != bundle["topic"]:
        raise ValueError("topic mismatch")
    for vector in bundle.get("canonical", []):
        if canonical(vector["value"]).hex() != vector["hex"] or digest(vector["value"]) != vector["sha256"]:
            raise ValueError("canonical mismatch")
    for vector in bundle["messages"]:
        m = verify(vector["wire"], bundle["pins"][vector["actor"]])
        if {k: m[k] for k in SCOPE} != bundle["scope"]:
            raise ValueError("scope mismatch")
        actor = decode(base64.b64decode(m["payload"], validate=True))["activity"]["actor"] if m["schema"] == AD else m.get("actor", m.get("from"))
        if actor != vector["actor"]:
            raise ValueError("actor mismatch")
        if "transcript_hex" in vector and transcript(m).hex() != vector["transcript_hex"]:
            raise ValueError("transcript mismatch")
        if m["schema"] == AD:
            payload = decode(base64.b64decode(m["payload"], validate=True))
            if digest(payload) != vector["content_hash"]:
                raise ValueError("content hash mismatch")
        elif m["schema"] == SYNC and m["kind"] == "offer":
            if digest({k: m[k] for k in BATCH_FIELDS}) != m["batch"]:
                raise ValueError("batch mismatch")


def generate():
    alpha, beta = (f"https://{n}.example/actors/shop" for n in ("alpha", "beta"))
    seeds = {alpha: bytes(range(32)), beta: bytes(range(32, 64))}
    pins = {actor: public_key(seed) for actor, seed in seeds.items()}
    scope = {"halaqa_id": "wire-vectors", "charter_hash": "a" * 64, "epoch": 9007199254740991}
    context, audience = "https://www.w3.org/ns/activitystreams", ["https://www.w3.org/ns/activitystreams#Public"]
    listing = "https://alpha.example/listings/part"
    messages = []

    def append(name, m, actor, **extra):
        m = sign(dict(scope, **m, publisher=pins[actor], announcement="01" * 16), seeds[actor])
        messages.append(dict(name=name, actor=actor, wire=canonical(m).decode(), transcript_hex=transcript(m).hex(), **extra))
        return m

    for revision, kind in enumerate(("Create", "Update", "Delete")):
        metadata = {"schema": "bizkit.marketplace.listing.v1", "id": listing, "seller": alpha,
                    "revision": revision, "name": 'Pièce "α" 🛠', "summary": "Line\nTab\tSlash/Back\\Control\x1b",
                    "category": "parts", "price": {"mode": "fixed", "currency": "USD", "minor_units": 9007199254740991}}
        obj = {"type": "Page", "id": listing, "attributedTo": alpha, "name": metadata["name"], "summary": metadata["summary"],
               "url": listing, "to": audience, "attachment": [{"type": "Link", "href": listing + ".json", "mediaType": "application/json"}]}
        if kind == "Delete":
            obj, metadata = {"type": "Tombstone", "id": listing}, None
        activity = {"@context": context, "id": alpha + "/activities/" + kind.lower(), "type": kind,
                    "actor": alpha, "to": audience, "object": obj}
        payload = {"activity": activity, "metadata": metadata}
        content_hash = digest(payload)
        append(kind.lower(), {"schema": AD, "payload": base64.b64encode(canonical(payload)).decode()}, alpha, content_hash=content_hash)
        if kind == "Create":
            create_id, create_hash = activity["id"], content_hash

    append("lease", {"schema": LEASE, "actor": alpha, "listing_id": listing, "activity_id": create_id,
                     "hash": create_hash, "sequence": 9007199254740991, "issued": 1700000000, "expires": 1700000300}, alpha)
    offer = dict(scope, schema=SYNC, kind="offer", publisher=pins[alpha], **{"from": alpha, "to": beta},
                 round="02" * 16, entries=[{"id": create_id, "hash": create_hash}], expires=1700003600)
    offer["batch"] = digest({k: offer[k] for k in BATCH_FIELDS})
    append("offer", {k: v for k, v in offer.items() if k not in (*SCOPE, "publisher")}, alpha)
    receipt = {k: v for k, v in offer.items() if k not in (*SCOPE, "publisher", "entries")}
    receipt.update(kind="receipt", **{"from": beta, "to": alpha}, journal="03" * 16)
    append("receipt", receipt, beta)
    values = [{"z": [True, False, None, 0, -1, 9007199254740991], "a": {"😀": "astral", "\ue000": "bmp", "é": "e\u0301"}},
              {"escapes": "".join(map(chr, range(32))) + '"\\/\u2028\u2029🛠'}]
    return {"profile": "bizkit.gossip-wire-vectors.v1", "test_only": True, "test_seeds": {a: s.hex() for a, s in seeds.items()},
            "scope": scope, "topic": topic(scope), "pins": pins, "now": 1700000000,
            "canonical": [{"value": v, "hex": canonical(v).hex(), "sha256": digest(v)} for v in values], "messages": messages}


if __name__ == "__main__":
    if sys.argv[1:] == ["generate"]:
        print(json.dumps(generate(), ensure_ascii=False, indent=2))
    elif len(sys.argv) == 3 and sys.argv[1] == "verify":
        check_bundle(json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")))
        print("wire signatures and commitments verified")
    else:
        raise SystemExit("usage: gossip_reference.py generate | verify bundle.json")
