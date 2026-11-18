"""Strict transport values and MCP-compatible, domain-separated receipts."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
CORE = ROOT.parent / "research_exchange"
MCP = ROOT.parent / "research_exchange_mcp"
sys.dont_write_bytecode = True
sys.path.insert(0, str(CORE))
sys.path.insert(0, str(MCP / "tools"))

MAX_ARTIFACT = 65_536
MAX_FRAME = 131_072
MAX_ENTRIES = 128
MAX_INTEGER = (1 << 63) - 1
SCHEMA = "research-exchange/bridge-rpc/v1"
VERIFIER = "local-reviewed-export-verifier"


class BridgeError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def require(condition: bool, code: str = "invalid_arguments") -> None:
    if not condition:
        raise BridgeError(code)


def exact(value, fields, code="invalid_arguments"):
    require(type(value) is dict and set(value) == set(fields), code)
    return value


def text(value, maximum=128):
    try:
        return type(value) is str and 0 < len(value.encode("utf-8")) <= maximum
    except UnicodeError:
        return False


def hexadecimal(value, length=64):
    return type(value) is str and re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is not None


def integer(value, minimum=0, maximum=MAX_INTEGER):
    return type(value) is int and minimum <= value <= maximum


def _valid_json(value):
    if type(value) is dict:
        for key, child in value.items():
            require(type(key) is str, "invalid_json")
            key.encode("utf-8")
            _valid_json(child)
    elif type(value) is list:
        for child in value:
            _valid_json(child)
    elif type(value) is str:
        value.encode("utf-8")
    else:
        require(value is None or type(value) in (int, bool), "invalid_json")


def canonical(value) -> bytes:
    _valid_json(value)
    def string(item):
        escapes = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f",
                   "\n": "\\n", "\r": "\\r", "\t": "\\t"}
        # OTP :json uses uppercase hex for the remaining control characters.
        # Encode characters directly: rewriting an encoded JSON string would
        # incorrectly change literal backslash-u text such as "\\u000B".
        return '"' + "".join(escapes.get(char, "\\u%04X" % ord(char) if ord(char) < 32 else char)
                             for char in item) + '"'

    def encode(item):
        if type(item) is str:
            return string(item)
        if type(item) is dict:
            return "{" + ",".join(string(key) + ":" + encode(item[key]) for key in sorted(item)) + "}"
        if type(item) is list:
            return "[" + ",".join(encode(child) for child in item) + "]"
        if item is None:
            return "null"
        if type(item) is bool:
            return "true" if item else "false"
        return str(item)
    return encode(value).encode("utf-8")


def loads(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "invalid_json")
            result[key] = value
        return result
    try:
        value = json.loads(data, object_pairs_hook=pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(BridgeError("invalid_json")))
        _valid_json(value)
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        raise BridgeError("invalid_json") from error


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest(domain: str, value) -> str:
    return sha(domain.encode("utf-8") + b"\n" + canonical(value))


def envelope(payload: dict, key: bytes) -> dict:
    data = b"research-exchange/receipt/v1\n" + canonical(payload)
    return {"payload": payload, "sha256": sha(data),
            "server_mac": hmac.new(key, data, "sha256").hexdigest()}


def token_hash(token) -> str:
    require(text(token, 512) and len(token.encode("utf-8")) >= 32, "unauthorized")
    return sha(token.encode("utf-8"))


def receipt_key(value):
    try:
        key = base64.b64decode(value, validate=True)
        require(len(key) >= 32, "invalid_configuration")
        return key
    except (ValueError, TypeError) as error:
        raise BridgeError("invalid_configuration") from error


def core_identity():
    from verify_core_snapshot import verify_snapshot
    return verify_snapshot()["reviewed_core"]


def load_config(path):
    value = loads(Path(path).read_bytes())
    required = {"database", "receipt_key_base64", "lean_root"}
    optional = {"worker_enabled", "poll_interval_ms", "test_failpoint", "test_job_id",
                "test_pause_after_check", "test_pause_job_id"}
    require(type(value) is dict and required <= set(value) <= required | optional,
            "invalid_configuration")
    for name in ("database", "lean_root"):
        require(type(value[name]) is str and Path(value[name]).is_absolute(), "invalid_configuration")
    receipt_key(value["receipt_key_base64"])
    require(type(value.get("worker_enabled", True)) is bool, "invalid_configuration")
    require(integer(value.get("poll_interval_ms", 200), 50, 5000), "invalid_configuration")
    require(value.get("test_failpoint") in (None, "before_commit", "after_commit"), "invalid_configuration")
    for name in ("test_job_id", "test_pause_job_id"):
        require(name not in value or hexadecimal(value[name]), "invalid_configuration")
    if "test_pause_after_check" in value:
        require(type(value["test_pause_after_check"]) is str and
                Path(value["test_pause_after_check"]).is_absolute(), "invalid_configuration")
    return value
