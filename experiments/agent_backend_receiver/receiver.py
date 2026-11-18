"""Staging reference receiver: durable request identities, never worker execution.

Only an owning trusted host may invoke this local stdio protocol. The receiver
does not verify signed business authority. Its fence orders against its own
SQLite create transaction, not against a commit in a different database.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import sys
from urllib.parse import quote


REQUEST_SCHEMA = "bizkit.agent-backend-request.v1"
RECEIPT_SCHEMA = "bizkit.agent-backend-receipt.v1"
ERROR_SCHEMA = "bizkit.agent-backend-error.v1"
STORE_SCHEMA = "bizkit.agent-backend-store.v1"
MAX_REQUEST_BYTES = 8192
APPLICATION_ID = 0x424B4142
STORE_ID = re.compile(r"agent-backend-store:[0-9a-f]{32}\Z")
EFFECT_ID = re.compile(r"agent-run:[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
PLAN_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
DEADLINE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)\Z")
BASE_KEYS = {"schema", "operation", "store_id", "effect_id"}
CREATE_KEYS = BASE_KEYS | {"admission_id", "plan_digest", "execution_deadline"}
REFUSALS = {"effect_fenced", "binding_conflict", "deadline_expired"}
ERRORS = REFUSALS | {
    "invalid_request", "invalid_arguments", "invalid_store", "store_missing",
    "store_exists", "store_identity_mismatch", "database_busy", "database_unavailable",
}

SCHEMA_STATEMENTS = (
    """CREATE TABLE store_metadata (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        schema_version INTEGER NOT NULL CHECK (schema_version = 1),
        store_id TEXT NOT NULL UNIQUE
    )""",
    """CREATE TABLE backend_requests (
        effect_id TEXT PRIMARY KEY NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('accepted', 'fenced')),
        backend_id TEXT UNIQUE,
        admission_id TEXT UNIQUE,
        plan_digest TEXT,
        execution_deadline TEXT,
        CHECK ((backend_id IS NULL AND admission_id IS NULL AND plan_digest IS NULL
                AND execution_deadline IS NULL AND state = 'fenced') OR
               (backend_id IS NOT NULL AND admission_id IS NOT NULL
                AND plan_digest IS NOT NULL AND execution_deadline IS NOT NULL))
    )""",
    """CREATE TRIGGER immutable_store_update BEFORE UPDATE ON store_metadata
        BEGIN SELECT RAISE(ABORT, 'immutable store identity'); END""",
    """CREATE TRIGGER immutable_store_delete BEFORE DELETE ON store_metadata
        BEGIN SELECT RAISE(ABORT, 'immutable store identity'); END""",
    """CREATE TRIGGER immutable_store_insert BEFORE INSERT ON store_metadata
        WHEN EXISTS (SELECT 1 FROM store_metadata)
        BEGIN SELECT RAISE(ABORT, 'immutable store identity'); END""",
    """CREATE TRIGGER immutable_request_binding BEFORE UPDATE ON backend_requests
        WHEN NEW.effect_id IS NOT OLD.effect_id
          OR NEW.backend_id IS NOT OLD.backend_id
          OR NEW.admission_id IS NOT OLD.admission_id
          OR NEW.plan_digest IS NOT OLD.plan_digest
          OR NEW.execution_deadline IS NOT OLD.execution_deadline
          OR (OLD.state = 'fenced' AND NEW.state IS NOT 'fenced')
        BEGIN SELECT RAISE(ABORT, 'immutable request binding or fence'); END""",
    """CREATE TRIGGER immutable_request_delete BEFORE DELETE ON backend_requests
        BEGIN SELECT RAISE(ABORT, 'retained request identity'); END""",
    """CREATE TRIGGER immutable_request_insert BEFORE INSERT ON backend_requests
        WHEN EXISTS (SELECT 1 FROM backend_requests
                     WHERE effect_id = NEW.effect_id OR backend_id = NEW.backend_id
                        OR admission_id = NEW.admission_id)
        BEGIN SELECT RAISE(ABORT, 'retained request identity'); END""",
)
SCHEMA_OBJECTS = {
    "store_metadata", "backend_requests", "immutable_store_update",
    "immutable_store_delete", "immutable_store_insert", "immutable_request_binding",
    "immutable_request_delete", "immutable_request_insert",
}


class Rejected(Exception):
    def __init__(self, code: str):
        assert code in ERRORS
        self.code = code
        super().__init__(code)


def _matches(pattern: re.Pattern, value: object) -> bool:
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def _error(code: str, store_id: str | None = None) -> tuple[dict, int]:
    return {"schema": ERROR_SCHEMA, "error": code, "store_id": store_id}, 1 if code in REFUSALS else 2


def _unique_object(pairs: list[tuple]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise Rejected("invalid_request")
        value[key] = item
    return value


def _decode(raw: bytes) -> dict:
    if not isinstance(raw, bytes) or not raw or len(raw) > MAX_REQUEST_BYTES:
        raise Rejected("invalid_request")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeError, ValueError, RecursionError):
        raise Rejected("invalid_request") from None
    if not isinstance(value, dict):
        raise Rejected("invalid_request")
    return value


def _deadline(value: object) -> str:
    if not _matches(DEADLINE, value):
        raise Rejected("invalid_request")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise Rejected("invalid_request") from None
    # The exact host-supplied spelling is part of the immutable request binding.
    return value


def _validate(value: dict) -> dict:
    operation = value.get("operation")
    expected = CREATE_KEYS if operation == "create" else BASE_KEYS
    if (operation not in ("create", "fence", "lookup") or set(value) != expected
            or value.get("schema") != REQUEST_SCHEMA
            or not _matches(STORE_ID, value.get("store_id"))
            or not _matches(EFFECT_ID, value.get("effect_id"))):
        raise Rejected("invalid_request")
    if operation == "create":
        expected_id = "agent-admission:" + hashlib.sha256(value["effect_id"].encode("utf-8")).hexdigest()
        if value["admission_id"] != expected_id or not _matches(PLAN_DIGEST, value["plan_digest"]):
            raise Rejected("invalid_request")
        value = {**value, "execution_deadline": _deadline(value["execution_deadline"])}
    return value


def _private_path(db: str, *, initializing: bool = False) -> Path:
    path = Path(os.path.abspath(db))
    try:
        # Reject symlinks in every existing component, including ancestors.
        for component in reversed((path.parent, *path.parent.parents)):
            info = component.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise Rejected("invalid_store")
        parent = path.parent.stat()
        if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700:
            raise Rejected("invalid_store")
        for suffix in ("-journal", "-wal", "-shm"):
            sidecar = Path(str(path) + suffix)
            try:
                entry = sidecar.lstat()
            except FileNotFoundError:
                continue  # Another legitimate process may have removed its journal.
            if (not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.getuid()
                    or stat.S_IMODE(entry.st_mode) != 0o600 or entry.st_nlink != 1):
                raise Rejected("invalid_store")
        try:
            info = path.lstat()
        except FileNotFoundError:
            if initializing:
                return path
            raise Rejected("store_missing") from None
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise Rejected("invalid_store")
        if initializing:
            raise Rejected("store_exists")
        return path
    except OSError:
        raise Rejected("invalid_store") from None


def _connect(path: Path) -> sqlite3.Connection:
    # mode=rw is essential: lost state must never become a fresh empty store.
    connection = sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=rw",
                                 uri=True, timeout=2.0, isolation_level=None)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA busy_timeout=2000")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA trusted_schema=OFF")
    except BaseException:
        connection.close()
        raise
    return connection


def _check_store(connection: sqlite3.Connection, expected_id: str) -> None:
    if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
        raise Rejected("invalid_store")
    if connection.execute("PRAGMA user_version").fetchone()[0] != 1:
        raise Rejected("invalid_store")
    objects = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_schema WHERE type IN ('table','trigger')")}
    if objects != SCHEMA_OBJECTS:
        raise Rejected("invalid_store")
    rows = connection.execute("SELECT singleton,schema_version,store_id FROM store_metadata").fetchall()
    if len(rows) != 1 or rows[0][0] != 1 or rows[0][1] != 1 or not _matches(STORE_ID, rows[0][2]):
        raise Rejected("invalid_store")
    if rows[0][2] != expected_id:
        raise Rejected("store_identity_mismatch")


def _receipt(request: dict, row: sqlite3.Row | None, disposition: str) -> dict:
    state = "unknown" if row is None else row["state"]
    return {
        "schema": RECEIPT_SCHEMA,
        "operation": request["operation"],
        "store_id": request["store_id"],
        "effect_id": request["effect_id"],
        "state": state,
        "backend_id": None if row is None else row["backend_id"],
        "admission_id": None if row is None else row["admission_id"],
        "plan_digest": None if row is None else row["plan_digest"],
        "execution_deadline": None if row is None else row["execution_deadline"],
        "disposition": disposition,
        "execution_started": False,
        "termination_verified": False,
        "future_creates_refused": state == "fenced",
    }


def _apply(connection: sqlite3.Connection, request: dict) -> dict:
    effect = request["effect_id"]
    row = connection.execute("SELECT * FROM backend_requests WHERE effect_id=?", (effect,)).fetchone()
    if request["operation"] == "lookup":
        return _receipt(request, row, "unknown" if row is None else
                        "fenced" if row["state"] == "fenced" else "existing")
    if request["operation"] == "fence":
        if row is None:
            connection.execute("INSERT INTO backend_requests(effect_id,state) VALUES(?, 'fenced')", (effect,))
        elif row["state"] != "fenced":
            connection.execute("UPDATE backend_requests SET state='fenced' WHERE effect_id=?", (effect,))
        row = connection.execute("SELECT * FROM backend_requests WHERE effect_id=?", (effect,)).fetchone()
        return _receipt(request, row, "fenced")
    if row is not None and row["state"] == "fenced":
        raise Rejected("effect_fenced")
    binding = (request["admission_id"], request["plan_digest"], request["execution_deadline"])
    if row is not None and binding != tuple(row[key] for key in
                                           ("admission_id", "plan_digest", "execution_deadline")):
        raise Rejected("binding_conflict")
    # This observation is AFTER BEGIN IMMEDIATE acquired the database write lock.
    if datetime.fromisoformat(request["execution_deadline"].replace("Z", "+00:00")) <= datetime.now(timezone.utc):
        raise Rejected("deadline_expired")
    disposition = "existing"
    if row is None:
        backend_id = "agent-backend:" + secrets.token_hex(16)
        connection.execute("""INSERT INTO backend_requests
            (effect_id,state,backend_id,admission_id,plan_digest,execution_deadline)
            VALUES(?, 'accepted', ?, ?, ?, ?)""", (effect, backend_id, *binding))
        row = connection.execute("SELECT * FROM backend_requests WHERE effect_id=?", (effect,)).fetchone()
        disposition = "created"
    return _receipt(request, row, disposition)


def _sqlite_error(error: sqlite3.Error) -> str:
    code = getattr(error, "sqlite_errorcode", 0)
    return "database_busy" if code & 0xff in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED) else "database_unavailable"


def _close(connection: sqlite3.Connection | None) -> None:
    if connection is not None:
        try:
            if connection.in_transaction:
                connection.rollback()
        except sqlite3.Error:
            pass  # A failed cleanup must not hide the original closed error response.
        finally:
            connection.close()


def handle_request(db: str, raw: bytes) -> tuple[dict, int]:
    """The CLI and crash fixture share this exact commit-before-return handler."""
    requested_id = None
    connection = None
    try:
        value = _decode(raw)
        if _matches(STORE_ID, value.get("store_id")):
            requested_id = value["store_id"]
        request = _validate(value)
        path = _private_path(db)
        connection = _connect(path)
        connection.execute("BEGIN IMMEDIATE")
        _check_store(connection, request["store_id"])
        response = _apply(connection, request)
        connection.execute("COMMIT")
        return response, 0
    except Rejected as error:
        return _error(error.code, requested_id)
    except sqlite3.Error as error:
        return _error(_sqlite_error(error), requested_id)
    except (OSError, ValueError):
        return _error("invalid_store", requested_id)
    finally:
        _close(connection)


def initialize(db: str) -> tuple[dict, int]:
    connection = None
    try:
        path = _private_path(db, initializing=True)
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        connection = _connect(path)
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("BEGIN IMMEDIATE")
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)
        store_id = "agent-backend-store:" + secrets.token_hex(16)
        connection.execute("INSERT INTO store_metadata VALUES(1,1,?)", (store_id,))
        connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
        connection.execute("PRAGMA user_version=1")
        connection.execute("COMMIT")
        return {"schema": STORE_SCHEMA, "store_id": store_id}, 0
    except FileExistsError:
        return _error("store_exists")
    except Rejected as error:
        return _error(error.code)
    except sqlite3.Error as error:
        return _error(_sqlite_error(error))
    except OSError:
        return _error("invalid_store")
    finally:
        _close(connection)


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise Rejected("invalid_arguments")


def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = _Parser(add_help=False)
    parser.add_argument("operation", choices=("init", "request"))
    parser.add_argument("--db", required=True)
    try:
        args = parser.parse_args(argv)
        response, status = initialize(args.db) if args.operation == "init" else handle_request(
            args.db, sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1))
    except Rejected as error:
        response, status = _error(error.code)
    print(json.dumps(response, sort_keys=True, separators=(",", ":")), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
