"""Offline Ed25519 experiment; no Halaqa adoption, ingress or effect authority.

OpenSSL verifies exact domain-separated bytes. Identity/context bindings are
explicit local TEST inputs, never assertions trusted from the signed frame.
"""
from __future__ import annotations

import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from halaqa_federation_draft import (
    HASH, MAX_EPOCH, TOKEN, Refused, _constant, _depth, _object, decode,
)

SCHEMA = "halaqa-federation-signed-experiment/draft-2"
DOMAIN = b"halaqa.federation.signed-experiment/draft-2\x00"
VERDICT = "SIGNATURE_VALID_AUTHORITY_UNVERIFIED"
CORPUS = "halaqa-federation-signed-vectors/draft-2"
FIELD_PRIME = 2**255 - 19
SCALAR_ORDER = 2**252 + 27742317777372353535851937790883648493
# Public compressed-y data from libsodium 1.0.18 ge25519_has_small_order.
# This is encoding refusal, not an implementation of curve arithmetic.
SMALL_ORDER_Y = {
    0, 1, FIELD_PRIME - 1,
    2707385501144840649318225287225658788936804267575313519463743609750303402022,
    55188659117513257062467267217118295137698188065244968500265048394206261417927,
}
FIELDS = {"schema", "candidate", "key_id", "issued_at", "expires_at", "signature"}
POLICY_FIELDS = {
    "sender", "recipient", "halaqa_id", "charter_hash", "epoch", "key_id",
    "public_key", "now", "revoked",
}


def _base64(value, size=None):
    if type(value) is not str:
        raise Refused("signed_encoding")
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, UnicodeError):
        raise Refused("signed_encoding") from None
    if base64.b64encode(data).decode("ascii") != value or (size is not None and len(data) != size):
        raise Refused("signed_encoding")
    return data


def transcript(candidate, key_id, issued_at, expires_at):
    """Proposed exact signing bytes; outer JSON serialization is never signed."""
    key = key_id.encode("ascii")
    return (DOMAIN + struct.pack(">I", len(key)) + key
            + struct.pack(">QQI", issued_at, expires_at, len(candidate)) + candidate)


def _policy(policy):
    if type(policy) is not dict or set(policy) != POLICY_FIELDS:
        raise Refused("test_policy")
    for field in ("sender", "recipient", "halaqa_id", "key_id"):
        if type(policy[field]) is not str or TOKEN.fullmatch(policy[field]) is None:
            raise Refused("test_policy")
    if (type(policy["charter_hash"]) is not str
            or HASH.fullmatch(policy["charter_hash"]) is None
            or type(policy["epoch"]) is not int or not 0 <= policy["epoch"] <= MAX_EPOCH
            or type(policy["now"]) is not int or not 0 <= policy["now"] <= MAX_EPOCH
            or type(policy["revoked"]) is not bool):
        raise Refused("test_policy")
    return _base64(policy["public_key"], 32)


def openssl_verify(public_key, signed_bytes, signature):
    """Use Ed25519 (not Ed25519ph); invoke a fixed program without a shell."""
    def point_encoding_allowed(point):
        y = int.from_bytes(point, "little") & (2**255 - 1)
        return y < FIELD_PRIME and y not in SMALL_ORDER_Y

    if (not point_encoding_allowed(public_key)
            or not point_encoding_allowed(signature[:32])
            or int.from_bytes(signature[32:], "little") >= SCALAR_ORDER):
        return False
    # RFC 8410 Ed25519 SubjectPublicKeyInfo + 32 raw public-key bytes.
    spki = bytes.fromhex("302a300506032b6570032100") + public_key
    try:
        with tempfile.TemporaryDirectory(prefix="halaqa-signed-test-") as directory:
            root = Path(directory)
            (root / "key.der").write_bytes(spki)
            (root / "message").write_bytes(signed_bytes)
            (root / "signature").write_bytes(signature)
            result = subprocess.run([
                "openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER",
                "-inkey", str(root / "key.der"), "-rawin", "-in", str(root / "message"),
                "-sigfile", str(root / "signature"),
            ], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Refused("verification_backend") from None
    return result.returncode == 0


def verify(wire, test_policy):
    """Verify one offline fixture against an externally supplied TEST policy."""
    public_key = _policy(test_policy)
    if type(wire) is not bytes or not 1 <= len(wire) <= 12_288:
        raise Refused("signed_wire_limit")
    _depth(wire)
    try:
        envelope = json.loads(wire.decode("utf-8"), object_pairs_hook=_object,
                              parse_constant=_constant)
    except Refused:
        raise
    except (ValueError, UnicodeError, RecursionError):
        raise Refused("invalid_json") from None
    if type(envelope) is not dict or set(envelope) != FIELDS:
        raise Refused("signed_fields")
    if envelope["schema"] != SCHEMA:
        raise Refused("signed_schema")
    key_id = envelope["key_id"]
    if type(key_id) is not str or TOKEN.fullmatch(key_id) is None:
        raise Refused("signed_key")
    issued, expires = envelope["issued_at"], envelope["expires_at"]
    if (type(issued) is not int or type(expires) is not int
            or not 0 <= issued < expires <= MAX_EPOCH or expires - issued > 300):
        raise Refused("signed_time")
    candidate = _base64(envelope["candidate"])
    signature = _base64(envelope["signature"], 64)
    decoded = decode(candidate)
    message = decoded["message"]
    if key_id != test_policy["key_id"] or message["sender"] != test_policy["sender"]:
        raise Refused("test_key_binding")
    if test_policy["revoked"]:
        raise Refused("test_key_revoked")
    if any(message[field] != test_policy[field]
           for field in ("recipient", "halaqa_id", "charter_hash", "epoch")):
        raise Refused("test_context")
    if not issued <= test_policy["now"] < expires:
        raise Refused("test_expiry")
    signed = transcript(candidate, key_id, issued, expires)
    if not openssl_verify(public_key, signed, signature):
        raise Refused("invalid_signature")
    return {"verdict": VERDICT, "payload": decoded["payload"], "transcript": signed}


def check_corpus(path: Path):
    corpus = json.loads(path.read_text("utf-8"), object_pairs_hook=_object,
                        parse_constant=_constant)
    if (type(corpus) is not dict or set(corpus) != {"schema", "scope", "vectors"}
            or corpus["schema"] != CORPUS or corpus["scope"] != "offline-signed-test-only"
            or type(corpus["vectors"]) is not list or not corpus["vectors"]):
        raise ValueError("invalid signed corpus")
    names = set()
    counts = {VERDICT: 0, "REFUSED_SIGNED_TEST": 0}
    for vector in corpus["vectors"]:
        if type(vector) is not dict or set(vector) != {
            "name", "wire_base64", "test_policy", "expected", "reason",
            "payload_base64", "transcript_base64",
        }:
            raise ValueError("invalid signed vector")
        name = vector["name"]
        if type(name) is not str or TOKEN.fullmatch(name) is None or name in names:
            raise ValueError("invalid signed vector name")
        names.add(name)
        expected = vector["expected"]
        if type(expected) is not str or expected not in counts:
            raise ValueError("invalid signed verdict")
        wire = _base64(vector["wire_base64"])
        try:
            result = verify(wire, vector["test_policy"])
        except Refused as exc:
            if expected != "REFUSED_SIGNED_TEST" or str(exc) != vector["reason"]:
                raise ValueError(f"{name}: unexpected signed refusal: {exc}") from exc
            if vector["payload_base64"] is not None or vector["transcript_base64"] is not None:
                raise ValueError("refused vector must not assert verified bytes")
        else:
            if (expected != VERDICT or vector["reason"] is not None
                    or base64.b64encode(result["payload"]).decode() != vector["payload_base64"]
                    or base64.b64encode(result["transcript"]).decode()
                    != vector["transcript_base64"]):
                raise ValueError(f"{name}: unexpected signed verdict or changed bytes")
        counts[expected] += 1
    if not all(counts.values()):
        raise ValueError("signed corpus requires positive and negative vectors")
    return {"scope": "offline-signed-test-only", "counts": counts,
            "authority_verified": False, "production_receiver": False}
