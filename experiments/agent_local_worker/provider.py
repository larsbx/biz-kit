"""Linux staging provider for one fixed, bounded, real local child workload.

This is not an agent sandbox. The owning host, local filesystem and fixed
worker implementation are trusted. Business authority is checked outside this
provider. Its permanent fence orders only with its own SQLite operations.
Ambiguous starting records are never respawned. No numeric PID is signalled.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import select
import signal
import sqlite3
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent
_base_spec = importlib.util.spec_from_file_location(
    "agent_receiver_file_contract", HERE.parent / "agent_backend_receiver" / "receiver.py")
base = importlib.util.module_from_spec(_base_spec)
_base_spec.loader.exec_module(base)

WORKER = HERE / "worker.py"
WORKLOAD_ID = "bizkit.fixed-local-worker.v1"
REQUEST_SCHEMA = "bizkit.agent-local-worker-request.v1"
RECEIPT_SCHEMA = "bizkit.agent-local-worker-receipt.v1"
ERROR_SCHEMA = "bizkit.agent-local-worker-error.v1"
STORE_SCHEMA = "bizkit.agent-local-worker-store.v1"
APPLICATION_ID = 0x424B4C57
MAX_REQUEST_BYTES = 8192
MAX_WORKER_SECONDS = 30
ERRORS = base.ERRORS | {"unsupported_platform", "spawn_unconfirmed"}
REFUSALS = base.REFUSALS | {"spawn_unconfirmed"}
IDENTITY_KEYS = ("boot_id", "pid", "start_ticks")

SCHEMA = (
    """CREATE TABLE store_metadata (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        schema_version INTEGER NOT NULL CHECK(schema_version=1),
        store_id TEXT NOT NULL UNIQUE,
        workload_id TEXT NOT NULL CHECK(workload_id='bizkit.fixed-local-worker.v1'))""",
    """CREATE TABLE local_workers (
        effect_id TEXT PRIMARY KEY NOT NULL,
        backend_id TEXT UNIQUE, admission_id TEXT UNIQUE, plan_digest TEXT,
        execution_deadline TEXT, launch_nonce TEXT UNIQUE, worker_argv TEXT,
        workload_id TEXT NOT NULL DEFAULT 'bizkit.fixed-local-worker.v1'
            CHECK(workload_id='bizkit.fixed-local-worker.v1'),
        fenced INTEGER NOT NULL DEFAULT 0 CHECK(fenced IN (0,1)),
        boot_id TEXT, pid INTEGER CHECK(pid>0), start_ticks INTEGER CHECK(start_ticks>=0),
        work_count INTEGER NOT NULL DEFAULT 0 CHECK(work_count IN (0,1)), result_digest TEXT,
        termination_verified INTEGER NOT NULL DEFAULT 0 CHECK(termination_verified IN (0,1)),
        CHECK((backend_id IS NULL AND admission_id IS NULL AND plan_digest IS NULL
               AND execution_deadline IS NULL AND launch_nonce IS NULL AND worker_argv IS NULL AND fenced=1
               AND pid IS NULL AND work_count=0 AND termination_verified=0) OR
              (backend_id IS NOT NULL AND admission_id IS NOT NULL AND plan_digest IS NOT NULL
               AND execution_deadline IS NOT NULL AND launch_nonce IS NOT NULL AND worker_argv IS NOT NULL)),
        CHECK((boot_id IS NULL AND pid IS NULL AND start_ticks IS NULL) OR
              (boot_id IS NOT NULL AND pid IS NOT NULL AND start_ticks IS NOT NULL)),
        CHECK((work_count=0 AND result_digest IS NULL) OR
              (work_count=1 AND result_digest IS NOT NULL AND length(result_digest)=64 AND pid IS NOT NULL)),
        CHECK(termination_verified=0 OR (fenced=1 AND pid IS NOT NULL)))""",
    """CREATE TRIGGER metadata_update BEFORE UPDATE ON store_metadata
        BEGIN SELECT RAISE(ABORT,'immutable store'); END""",
    """CREATE TRIGGER metadata_delete BEFORE DELETE ON store_metadata
        BEGIN SELECT RAISE(ABORT,'immutable store'); END""",
    """CREATE TRIGGER metadata_insert BEFORE INSERT ON store_metadata
        WHEN EXISTS(SELECT 1 FROM store_metadata)
        BEGIN SELECT RAISE(ABORT,'immutable store'); END""",
    """CREATE TRIGGER worker_delete BEFORE DELETE ON local_workers
        BEGIN SELECT RAISE(ABORT,'permanent execution identity'); END""",
    """CREATE TRIGGER worker_insert BEFORE INSERT ON local_workers
        WHEN EXISTS(SELECT 1 FROM local_workers WHERE effect_id=NEW.effect_id
          OR backend_id=NEW.backend_id OR admission_id=NEW.admission_id
          OR launch_nonce=NEW.launch_nonce)
        BEGIN SELECT RAISE(ABORT,'permanent execution identity'); END""",
    """CREATE TRIGGER worker_binding BEFORE UPDATE ON local_workers
        WHEN NEW.effect_id IS NOT OLD.effect_id OR NEW.backend_id IS NOT OLD.backend_id
          OR NEW.admission_id IS NOT OLD.admission_id OR NEW.plan_digest IS NOT OLD.plan_digest
          OR NEW.execution_deadline IS NOT OLD.execution_deadline
          OR NEW.launch_nonce IS NOT OLD.launch_nonce OR NEW.worker_argv IS NOT OLD.worker_argv
          OR NEW.workload_id IS NOT OLD.workload_id
          OR NEW.fenced < OLD.fenced OR NEW.work_count < OLD.work_count
          OR NEW.termination_verified < OLD.termination_verified
          OR (OLD.pid IS NOT NULL AND (NEW.pid IS NOT OLD.pid
              OR NEW.boot_id IS NOT OLD.boot_id OR NEW.start_ticks IS NOT OLD.start_ticks))
          OR (OLD.result_digest IS NOT NULL AND NEW.result_digest IS NOT OLD.result_digest)
        BEGIN SELECT RAISE(ABORT,'immutable binding or monotonic lifecycle'); END""",
)
OBJECTS = {"store_metadata", "local_workers", "metadata_update", "metadata_delete",
           "metadata_insert", "worker_delete", "worker_insert", "worker_binding"}


class Rejected(Exception):
    def __init__(self, code):
        assert code in ERRORS
        self.code = code
        super().__init__(code)


def _error(code, store_id=None):
    return {"schema": ERROR_SCHEMA, "error": code, "store_id": store_id}, 1 if code in REFUSALS else 2


def _platform():
    if not (sys.platform == "linux" and hasattr(os, "pidfd_open")
            and hasattr(signal, "pidfd_send_signal")):
        raise Rejected("unsupported_platform")


def _validate(value):
    if value.get("schema") != REQUEST_SCHEMA:
        raise Rejected("invalid_request")
    operation = value.get("operation")
    normalized = base._validate({**value, "schema": base.REQUEST_SCHEMA,
                                 "operation": "fence" if operation == "terminate" else operation})
    return {**normalized, "schema": REQUEST_SCHEMA, "operation": operation}


def _check_store(connection, expected_id=None):
    if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
        raise Rejected("invalid_store")
    if connection.execute("PRAGMA user_version").fetchone()[0] != 1:
        raise Rejected("invalid_store")
    names = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_schema WHERE type IN ('table','trigger')")}
    if names != OBJECTS:
        raise Rejected("invalid_store")
    rows = connection.execute("SELECT * FROM store_metadata").fetchall()
    if (len(rows) != 1 or rows[0]["singleton"] != 1 or rows[0]["schema_version"] != 1
            or rows[0]["workload_id"] != WORKLOAD_ID
            or not base._matches(base.STORE_ID, rows[0]["store_id"])):
        raise Rejected("invalid_store")
    if expected_id is not None and rows[0]["store_id"] != expected_id:
        raise Rejected("store_identity_mismatch")
    return rows[0]["store_id"]


def _connect(db):
    return base._connect(base._private_path(str(db)))


def _get_row(connection, effect):
    value = connection.execute("SELECT * FROM local_workers WHERE effect_id=?", (effect,)).fetchone()
    if value is None:
        return None
    return {**dict(value), "store_id": _check_store(connection)}


def _read_row(db, effect, store_id=None):
    connection = _connect(db)
    try:
        _check_store(connection, store_id)
        return _get_row(connection, effect)
    finally:
        base._close(connection)


def _artifact_path(db, row):
    return Path(db).absolute().parent / ("w-" + row["backend_id"].split(":", 1)[1] + ".sha256")


def _identity(pid=None):
    pid = os.getpid() if pid is None else pid
    boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    # comm can contain spaces and ')'; stat's final ')' closes that field.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return {"boot_id": boot_id, "pid": pid, "start_ticks": int(fields[19])}


def _recorded_identity(row):
    return None if row is None or row["pid"] is None else {key: row[key] for key in IDENTITY_KEYS}


def _pidfd_for_worker(db, row):
    """Return one caller-owned pidfd bound to the fixed trusted worker.

    The irreversible reservation permits one spawn with this random nonce.
    Check boot/PID/start/UID and the complete immutable argv both before and
    after opening the pidfd. Benign PID reuse cannot reproduce that nonce.
    Malicious same-UID host/code and database rollback are outside this local
    trusted-host boundary. No numeric-PID signal or absence inference exists.
    """
    row = dict(row)
    identity = _recorded_identity(row)
    if identity is None:
        raise Rejected("spawn_unconfirmed")
    _match_process(row)
    fd = os.pidfd_open(identity["pid"])
    try:
        os.set_inheritable(fd, False)
        _match_process(row)
        fdinfo = Path(f"/proc/self/fdinfo/{fd}").read_text()
        match = re.search(r"^Pid:\s+([0-9]+)$", fdinfo, flags=re.MULTILINE)
        if match is None or int(match[1]) != identity["pid"]:
            raise Rejected("spawn_unconfirmed")
        # A zero signal validates the kernel pidfd API without changing the process.
        signal.pidfd_send_signal(fd, 0)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _match_process(row):
    identity = _recorded_identity(row)
    if identity is None or _identity(identity["pid"]) != identity:
        raise Rejected("spawn_unconfirmed")
    process = Path(f"/proc/{identity['pid']}")
    if process.stat().st_uid != os.getuid():
        raise Rejected("spawn_unconfirmed")
    command = json.loads(row["worker_argv"])
    if (not isinstance(command, list) or len(command) != 6
            or not all(isinstance(argument, str) for argument in command)
            or command[1] != "-I" or command[-2:] != [row["effect_id"], row["launch_nonce"]]
            or not all(Path(command[index]).is_absolute() for index in (0, 2, 3))):
        raise Rejected("spawn_unconfirmed")
    expected = b"\0".join(os.fsencode(argument) for argument in command) + b"\0"
    with (process / "cmdline").open("rb") as source:
        actual = source.read(len(expected) + 1)
    if actual != expected:
        raise Rejected("spawn_unconfirmed")


def _exited(pidfd, milliseconds):
    poller = select.poll()
    poller.register(pidfd, select.POLLIN | select.POLLHUP)
    return any(events & (select.POLLIN | select.POLLHUP)
               for _descriptor, events in poller.poll(milliseconds))


def _after_reservation(_row):
    """No-op seam for isolated fault-injection fixtures; no CLI control flag."""


def _after_spawn(_child, _row):
    """Called after the spawning transaction commits and releases its lock."""


def _before_response(_response):
    """No-op response-loss seam for isolated fault-injection fixtures."""


def _spawn_worker(db, row):
    # No inherited host credentials, shell, arbitrary work parameters, or FDs.
    command = _worker_argv(db, row)
    if json.loads(row["worker_argv"]) != command:
        raise Rejected("spawn_unconfirmed")
    return subprocess.Popen(command,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            close_fds=True, start_new_session=True, env={"LANG": "C.UTF-8"})


def _worker_argv(db, row):
    return [str(Path(sys.executable).absolute()), "-I", str(Path(WORKER).absolute()),
            str(Path(db).absolute()), row["effect_id"], row["launch_nonce"]]


def _expired(row):
    return datetime.fromisoformat(row["execution_deadline"].replace("Z", "+00:00")) <= datetime.now(timezone.utc)


def _reserve(db, request):
    connection = _connect(db)
    try:
        connection.execute("BEGIN IMMEDIATE")
        _check_store(connection, request["store_id"])
        row = _get_row(connection, request["effect_id"])
        if row is not None and row["fenced"]:
            raise Rejected("effect_fenced")
        if row is not None and any(row[key] != request[key] for key in
                                   ("admission_id", "plan_digest", "execution_deadline")):
            raise Rejected("binding_conflict")
        if _expired(request):
            raise Rejected("deadline_expired")
        created = row is None
        if created:
            backend = "agent-backend:" + secrets.token_hex(16)
            nonce = secrets.token_hex(32)
            command = _worker_argv(db, {"effect_id": request["effect_id"], "launch_nonce": nonce})
            connection.execute("""INSERT INTO local_workers
                (effect_id,backend_id,admission_id,plan_digest,execution_deadline,launch_nonce,worker_argv)
                VALUES(?,?,?,?,?,?,?)""", (request["effect_id"], backend, request["admission_id"],
                                          request["plan_digest"], request["execution_deadline"], nonce,
                                          json.dumps(command, separators=(",", ":"))))
            row = _get_row(connection, request["effect_id"])
        connection.execute("COMMIT")
        return row, created
    finally:
        base._close(connection)


def _spawn_reserved(db, reserved):
    connection = _connect(db)
    child = None
    try:
        connection.execute("BEGIN IMMEDIATE")
        _check_store(connection, reserved["store_id"])
        row = _get_row(connection, reserved["effect_id"])
        if row is None or row["launch_nonce"] != reserved["launch_nonce"]:
            raise Rejected("spawn_unconfirmed")
        if row["fenced"]:
            raise Rejected("effect_fenced")
        if _expired(row):
            raise Rejected("deadline_expired")
        # The original creator alone reaches this call, exactly once. A fresh
        # manager seeing a durable reservation must never attempt this path.
        child = _spawn_worker(db, row)
        connection.execute("COMMIT")
    finally:
        base._close(connection)
    _after_spawn(child, reserved)
    return child


def _fence(db, request):
    connection = _connect(db)
    try:
        connection.execute("BEGIN IMMEDIATE")
        _check_store(connection, request["store_id"])
        row = _get_row(connection, request["effect_id"])
        if row is None:
            connection.execute("INSERT INTO local_workers(effect_id,fenced) VALUES(?,1)", (request["effect_id"],))
        elif not row["fenced"]:
            connection.execute("UPDATE local_workers SET fenced=1 WHERE effect_id=?", (request["effect_id"],))
        row = _get_row(connection, request["effect_id"])
        connection.execute("COMMIT")
        return row
    finally:
        base._close(connection)


def _terminate(db, row):
    if row["termination_verified"] or row["pid"] is None:
        return row, None if row["termination_verified"] or row["backend_id"] is None else "unregistered_start"
    pidfd = None
    try:
        pidfd = _pidfd_for_worker(db, row)
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        except ProcessLookupError:
            pass
        ended = _exited(pidfd, 500)
        if not ended:
            try:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            ended = _exited(pidfd, 2000)
        if not ended:
            return row, "termination_timeout"
        connection = _connect(db)
        try:
            connection.execute("BEGIN IMMEDIATE")
            _check_store(connection, row["store_id"])
            current = _get_row(connection, row["effect_id"])
            if (_recorded_identity(current) != _recorded_identity(row)
                    or current["launch_nonce"] != row["launch_nonce"] or not current["fenced"]):
                raise Rejected("spawn_unconfirmed")
            connection.execute("UPDATE local_workers SET termination_verified=1 WHERE effect_id=?", (row["effect_id"],))
            row = _get_row(connection, row["effect_id"])
            connection.execute("COMMIT")
            return row, None
        finally:
            base._close(connection)
    except (OSError, ValueError, Rejected):
        return row, "worker_unreachable"
    finally:
        if pidfd is not None:
            os.close(pidfd)


def _observe(db, row):
    if row is None or row["backend_id"] is None or row["termination_verified"]:
        return None
    if row["pid"] is None:
        return "unregistered_start"
    pidfd = None
    try:
        pidfd = _pidfd_for_worker(db, row)
        return "worker_unreachable" if _exited(pidfd, 0) else None
    except (OSError, ValueError, Rejected):
        return "worker_unreachable"
    finally:
        if pidfd is not None:
            os.close(pidfd)


def _receipt(request, row, disposition, ambiguity=None):
    no_start = row is not None and row["backend_id"] is None
    verified = row is not None and bool(row["termination_verified"])
    work_count = 0 if row is None else row["work_count"]
    fenced = row is not None and bool(row["fenced"])
    state = ("unknown" if row is None else "terminated" if verified else "fenced" if fenced
             else "running" if work_count else "starting")
    if ambiguity is None and row is None:
        ambiguity = "no_record"
    if ambiguity is None and row is not None and not no_start and not verified and not work_count:
        ambiguity = "unregistered_start" if row["pid"] is None else "work_not_acknowledged"
    return {"schema": RECEIPT_SCHEMA, "operation": request["operation"],
            "store_id": request["store_id"], "effect_id": request["effect_id"], "state": state,
            "backend_id": None if row is None else row["backend_id"],
            "admission_id": None if row is None else row["admission_id"],
            "plan_digest": None if row is None else row["plan_digest"],
            "execution_deadline": None if row is None else row["execution_deadline"],
            "disposition": disposition, "execution_started": True if work_count else False if no_start else None,
            "termination_verified": verified, "future_creates_refused": fenced,
            "worker_identity": _recorded_identity(row), "work_count": work_count,
            "result_digest": None if row is None else row["result_digest"], "ambiguity": ambiguity}


def handle_request(db, raw):
    requested_id = None
    try:
        value = base._decode(raw)
        if base._matches(base.STORE_ID, value.get("store_id")):
            requested_id = value["store_id"]
        request = _validate(value)
        _platform()
        operation = request["operation"]
        ambiguity = None
        if operation == "create":
            row, created = _reserve(db, request)
            if created:
                _after_reservation(row)
                _spawn_reserved(db, row)
                until = time.monotonic() + 5.0
                while time.monotonic() < until:
                    row = _read_row(db, request["effect_id"], requested_id)
                    if row["work_count"] or row["fenced"]:
                        break
                    time.sleep(0.01)
            disposition = "created" if created else "existing"
            ambiguity = _observe(db, row)
        elif operation in ("fence", "terminate"):
            row = _fence(db, request)
            disposition = "fenced"
            if operation == "terminate":
                row, ambiguity = _terminate(db, row)
                disposition = "terminated" if row["termination_verified"] else "unresolved" if row["backend_id"] else "fenced"
        else:
            row = _read_row(db, request["effect_id"], requested_id)
            disposition = "unknown" if row is None else "existing"
            ambiguity = _observe(db, row)
        response = _receipt(request, row, disposition, ambiguity)
        _before_response(response)
        return response, 0
    except (Rejected, base.Rejected) as error:
        return _error(error.code, requested_id)
    except sqlite3.Error as error:
        return _error(base._sqlite_error(error), requested_id)
    except (OSError, ValueError):
        return _error("spawn_unconfirmed", requested_id)


def initialize(db):
    connection = None
    try:
        _platform()
        path = base._private_path(str(db), initializing=True)
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        connection = base._connect(path)
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.execute("BEGIN IMMEDIATE")
        for statement in SCHEMA:
            connection.execute(statement)
        store_id = "agent-backend-store:" + secrets.token_hex(16)
        connection.execute("INSERT INTO store_metadata VALUES(1,1,?,?)", (store_id, WORKLOAD_ID))
        connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
        connection.execute("PRAGMA user_version=1")
        connection.execute("COMMIT")
        return {"schema": STORE_SCHEMA, "store_id": store_id}, 0
    except FileExistsError:
        return _error("store_exists")
    except (Rejected, base.Rejected) as error:
        return _error(error.code)
    except sqlite3.Error as error:
        return _error(base._sqlite_error(error))
    except OSError:
        return _error("invalid_store")
    finally:
        base._close(connection)


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise Rejected("invalid_arguments")


def main(argv=None):
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
