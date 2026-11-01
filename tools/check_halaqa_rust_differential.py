#!/usr/bin/env python3
"""Offline diagnosis of fixed synthetic probes; disagreements are NOT conformance.

The Rust verifier never invokes Python. This external runner checks the pinned
Python reference independently, then compares its outcomes to Rust's fixed probes.
No test policy or candidate can reach a live receiver or admission API.
"""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import types

from check_halaqa_federation_draft import check

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tools/halaqa_federation_draft"


def run():
    baseline = check(ROOT)  # all four source hashes, 88 vectors, exact reasons
    pin = json.loads((FIXTURES / "source-pin.json").read_bytes())
    modules = []
    for filename in ("halaqa_federation_draft.py", "halaqa_federation_signed_draft.py"):
        data = (FIXTURES / filename).read_bytes()
        if hashlib.sha256(data).hexdigest() != pin["files"][filename]["sha256"]:
            raise ValueError("source changed during probe")
        module = types.ModuleType(filename.removesuffix(".py"))
        # The signed module imports only the verified candidate module here.
        sys.modules[module.__name__] = module
        exec(compile(data, str(FIXTURES / filename), "exec"), module.__dict__)
        modules.append(module)
    candidate, signed = modules
    fixture = json.loads((FIXTURES / "signed-vectors.json").read_bytes())["vectors"][0]
    envelope = json.loads(base64.b64decode(fixture["wire_base64"], validate=True))
    policy = dict(fixture["test_policy"])
    policy["public_key"] = base64.b64encode(b"\x01" + b"\0" * 31).decode()
    envelope["signature"] = base64.b64encode(b"\x01" + b"\0" * 63).decode()
    try:
        weak = signed.verify(json.dumps(envelope).encode(), policy)["verdict"]
    except candidate.Refused as exc:
        weak = str(exc)
    raw = base64.b64decode(envelope["candidate"], validate=True)
    probes = {
        "lone-surrogate": raw.replace(b"actor:alpha", br"\ud800"),
        "negative-zero-epoch": raw.replace(b'"epoch":1', b'"epoch":-0'),
        "overflow-epoch": raw.replace(b'"epoch":1', b'"epoch":1e400'),
    }
    reference = {"weak-identity-key": weak}
    for name, wire in probes.items():
        if wire == raw:
            raise ValueError(f"{name}: probe was not mutated")
        try:
            reference[name] = candidate.decode(wire)["verdict"]
        except candidate.Refused as exc:
            reference[name] = str(exc)
    native = subprocess.run([
        "cargo", "run", "--locked", "--offline", "--quiet", "--manifest-path",
        "tools/halaqa_signed_rust/Cargo.toml",
    ], cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, timeout=120, check=True)
    rust = json.loads(native.stdout)
    if (rust["source_revision"] != pin["revision"]
            or rust["authority_verified"] is not False
            or rust["production_receiver"] is not False
            or rust["signed"] != {
                "valid_unverified": 8, "refused": 40,
                "sha256": pin["files"]["signed-vectors.json"]["sha256"],
            }):
        raise ValueError("Rust source scope/counts changed")
    expected_reference = {
        "weak-identity-key": "SIGNATURE_VALID_AUTHORITY_UNVERIFIED",
        "lone-surrogate": "identifier",
        "negative-zero-epoch": "FORMAT_ONLY_UNVERIFIED",
        "overflow-epoch": "epoch",
    }
    expected_rust = {**expected_reference, "weak-identity-key": "invalid_signature",
                     "lone-surrogate": "invalid_json"}
    if reference != expected_reference or rust["edge_probes"] != expected_rust:
        raise ValueError(f"new or changed differential: Python={reference}, Rust={rust['edge_probes']}")
    return {
        "source_revision": baseline["source_revision"],
        "scope": "offline-diagnostic-known-disagreements-not-profile-approval",
        "python_openssl": reference,
        "rust_dalek_strict": rust["edge_probes"],
        "known_disagreements": ["weak-identity-key", "lone-surrogate"],
        "authority_verified": False, "production_receiver": False,
    }


if __name__ == "__main__":
    print(json.dumps(run(), sort_keys=True))
