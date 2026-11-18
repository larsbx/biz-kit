"""Shared bounded input and immutable profile definitions for the local pilot."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from typing import Any

from reference import codec

MAX_INTEGER = (1 << 63) - 1
MAX_ARTIFACT = 2 * 1024 * 1024
MAX_BODY = ((MAX_ARTIFACT + 2) // 3) * 4 + 4096
MAX_TTL_MS = 86_400_000
PROFILE_SCHEMA = "research-exchange/controlled-proof-profile/v1"
EXPECTED_THEOREM = "ResearchExchange.Adapter.expected_fixture"
ALTERNATE_THEOREM = "ResearchExchange.Adapter.alternate_fixture"
PROFILE_MODULE = "ResearchExchange.Adapter"
POLICY = {
    "profile": "exact-reviewed-export-only/v1",
    "required_checkers": ["leanchecker", "lean4lean"],
    "allowed_axioms": ["Classical.choice", "Quot.sound", "propext"],
    "authority": "local-fixture-credit-only",
}


class PilotError(Exception):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code
        super().__init__(code)


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("ascii")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def bounded(value: Any, *, minimum: int = 0, maximum: int = MAX_INTEGER) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise PilotError(400, "invalid_integer")
    return value


def identifier(value: Any) -> str:
    if type(value) is not str or re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", value) is None:
        raise PilotError(400, "invalid_identifier")
    return value


def exact_fields(value: Any, fields: tuple[str, ...]) -> dict:
    if type(value) is not dict or set(value) != set(fields):
        raise PilotError(400, "invalid_fields")
    return value


def parse_json(data: bytes) -> Any:
    try:
        return codec.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise PilotError(400, "invalid_json") from exc


def token_digest(token: Any) -> str:
    # Tokens are opaque high-entropy ASCII values, never user/worker identifiers.
    if type(token) is not str or re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token) is None:
        raise PilotError(401, "unauthorized")
    return digest(b"research-exchange-pilot/credential/v1\0" + token.encode("ascii"))


def source_identity(package_root: Path) -> dict[str, str]:
    lean = package_root / "formal/lean"
    paths = [lean / "ResearchExchange.lean", lean / "lakefile.toml",
             lean / "lake-manifest.json", lean / "lean-toolchain",
             package_root / "toolchains.lock.json"]
    paths.extend(sorted((lean / "ResearchExchange").glob("*.lean")))
    return {path.relative_to(package_root).as_posix(): file_digest(path) for path in paths}


def profile_binding(profile: dict) -> dict[str, int]:
    # Full SHA-256 commitments are Nat values in canonical JSON, never SQLite
    # INTEGER columns. Credits, principal IDs, versions and clocks are bounded.
    return {
        "target": int(digest(profile["theorem"].encode("ascii")), 16),
        "input": int(profile["source_sha256"], 16),
        "environment": int(profile["toolchain_lock_sha256"], 16),
        "policy": int(digest(canonical(POLICY)), 16),
    }


def validate_profile(profile: Any) -> dict:
    exact_fields(profile, ("schema", "module", "theorem", "source_sha256",
                           "source_files", "artifact_sha256", "artifact_bytes",
                           "toolchain_lock_sha256", "tool_sha256", "axioms", "policy"))
    if (profile["schema"] != PROFILE_SCHEMA or profile["module"] != PROFILE_MODULE
            or profile["theorem"] != EXPECTED_THEOREM or profile["policy"] != POLICY):
        raise PilotError(400, "invalid_profile")
    for field in ("source_sha256", "artifact_sha256", "toolchain_lock_sha256"):
        if type(profile[field]) is not str or re.fullmatch(r"[a-f0-9]{64}", profile[field]) is None:
            raise PilotError(400, "invalid_profile")
    if type(profile["source_files"]) is not dict or not profile["source_files"]:
        raise PilotError(400, "invalid_profile")
    if digest(canonical(profile["source_files"])) != profile["source_sha256"]:
        raise PilotError(400, "invalid_profile")
    if type(profile["tool_sha256"]) is not dict or set(profile["tool_sha256"]) != {
        "lean", "leanexport", "leanchecker", "lean4lean", "leanshared"
    }:
        raise PilotError(400, "invalid_profile")
    for h in [*profile["source_files"].values(), *profile["tool_sha256"].values()]:
        if type(h) is not str or re.fullmatch(r"[a-f0-9]{64}", h) is None:
            raise PilotError(400, "invalid_profile")
    if (type(profile["axioms"]) is not list
            or any(type(x) is not str for x in profile["axioms"])
            or len(profile["axioms"]) != len(set(profile["axioms"]))
            or not set(profile["axioms"]) <= set(POLICY["allowed_axioms"])):
        raise PilotError(400, "invalid_profile")
    bounded(profile["artifact_bytes"], minimum=1, maximum=MAX_ARTIFACT)
    return profile

