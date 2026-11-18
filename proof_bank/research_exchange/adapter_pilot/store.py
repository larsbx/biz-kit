"""SQLite transactional adapter for one independently provisioned reward slot.

All balances are disposable fixture credits. This module does not write the
Biz-kit signed business history or any financial provider. Provisioning and
credential administration are trusted offline operations, never HTTP routes.
"""
from __future__ import annotations

import base64
import binascii
from contextlib import contextmanager
from dataclasses import dataclass
import hmac
import json
from pathlib import Path
import sqlite3
import time
from typing import Callable

from reference import codec
from reference.kernel import (Accept, Lease, RewardConfig, RewardPhase, Submit,
                              Tick, initial_reward, reject_reward, reward_step)

from .checker import CheckedExport, RejectedExport, matches_export
from .common import (MAX_ARTIFACT, MAX_INTEGER, MAX_TTL_MS, PilotError, bounded,
                     canonical, digest, exact_fields, identifier, profile_binding,
                     token_digest, validate_profile)


@dataclass(frozen=True)
class Reply:
    status: int
    body: dict


@dataclass(frozen=True)
class PreparedVerification:
    slot_id: str
    version: int
    principal: int
    token_hash: str
    credential_epoch: int
    request_id: str
    request_sha256: str
    profile_json: str
    profile_sha256: str
    config_sha256: str
    candidate_json: str
    candidate_sha256: str
    artifact_sha256: str
    artifact: bytes

    @property
    def profile(self) -> dict:
        return json.loads(self.profile_json)


SCHEMA = """
CREATE TABLE IF NOT EXISTS slots (
    slot_id TEXT PRIMARY KEY,
    config_json TEXT NOT NULL,
    config_sha256 TEXT NOT NULL,
    profile_json TEXT NOT NULL,
    profile_sha256 TEXT NOT NULL,
    state_json TEXT NOT NULL,
    version INTEGER NOT NULL CHECK(version >= 0),
    artifact BLOB,
    artifact_sha256 TEXT,
    candidate_sha256 TEXT
);
CREATE TABLE IF NOT EXISTS credentials (
    token_hash TEXT PRIMARY KEY,
    principal INTEGER NOT NULL CHECK(principal > 0),
    role TEXT NOT NULL CHECK(role IN ('worker', 'verifier')),
    enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
    epoch INTEGER NOT NULL CHECK(epoch >= 0)
);
CREATE TABLE IF NOT EXISTS credential_scopes (
    token_hash TEXT NOT NULL REFERENCES credentials(token_hash),
    slot_id TEXT NOT NULL REFERENCES slots(slot_id),
    PRIMARY KEY(token_hash, slot_id)
);
CREATE TABLE IF NOT EXISTS requests (
    principal INTEGER NOT NULL,
    request_id TEXT NOT NULL,
    request_sha256 TEXT NOT NULL,
    operation TEXT NOT NULL,
    slot_id TEXT NOT NULL REFERENCES slots(slot_id),
    status_code INTEGER NOT NULL,
    response_json TEXT NOT NULL,
    PRIMARY KEY(principal, request_id)
);
CREATE TABLE IF NOT EXISTS settlements (
    slot_id TEXT PRIMARY KEY REFERENCES slots(slot_id),
    settlement_id TEXT NOT NULL UNIQUE,
    candidate_sha256 TEXT NOT NULL,
    profile_sha256 TEXT NOT NULL,
    worker INTEGER NOT NULL,
    amount INTEGER NOT NULL CHECK(amount >= 0),
    before_version INTEGER NOT NULL,
    version INTEGER NOT NULL,
    receipt_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS refunds (
    slot_id TEXT PRIMARY KEY REFERENCES slots(slot_id),
    refund_id TEXT NOT NULL UNIQUE,
    candidate_sha256 TEXT NOT NULL,
    profile_sha256 TEXT NOT NULL,
    amount INTEGER NOT NULL CHECK(amount > 0),
    before_version INTEGER NOT NULL,
    version INTEGER NOT NULL,
    receipt_json TEXT NOT NULL
);
CREATE TRIGGER IF NOT EXISTS exclusive_refund
BEFORE INSERT ON refunds WHEN EXISTS (SELECT 1 FROM settlements WHERE slot_id=NEW.slot_id)
BEGIN SELECT RAISE(ABORT, 'slot already settled'); END;
CREATE TRIGGER IF NOT EXISTS exclusive_settlement
BEFORE INSERT ON settlements WHEN EXISTS (SELECT 1 FROM refunds WHERE slot_id=NEW.slot_id)
BEGIN SELECT RAISE(ABORT, 'slot already refunded'); END;
CREATE TRIGGER IF NOT EXISTS immutable_refund
BEFORE UPDATE ON refunds
BEGIN SELECT RAISE(ABORT, 'immutable refund'); END;
CREATE TRIGGER IF NOT EXISTS permanent_refund
BEFORE DELETE ON refunds
BEGIN SELECT RAISE(ABORT, 'immutable refund'); END;
CREATE TRIGGER IF NOT EXISTS immutable_closed_slot
BEFORE UPDATE ON slots WHEN json_extract(OLD.state_json, '$.phase') IN ('accepted', 'rejected')
BEGIN SELECT RAISE(ABORT, 'immutable terminal slot'); END;
CREATE TRIGGER IF NOT EXISTS immutable_slot_config
BEFORE UPDATE OF config_json, config_sha256, profile_json, profile_sha256 ON slots
BEGIN SELECT RAISE(ABORT, 'immutable slot configuration'); END;
CREATE TRIGGER IF NOT EXISTS immutable_settlement
BEFORE UPDATE ON settlements
BEGIN SELECT RAISE(ABORT, 'immutable settlement'); END;
CREATE TRIGGER IF NOT EXISTS permanent_request_binding
BEFORE UPDATE ON requests
BEGIN SELECT RAISE(ABORT, 'immutable request receipt'); END;
"""


class Store:
    def __init__(self, db_path: str | Path, *, clock_ms: Callable[[], int] | None = None):
        if str(db_path) == ":memory:":
            raise ValueError("the acceptance pilot requires a file-backed database")
        self.path = Path(db_path).resolve()
        self.clock_ms = clock_ms or (lambda: time.time_ns() // 1_000_000)

    @contextmanager
    def connection(self):
        conn = sqlite3.connect(self.path, isolation_level=None, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("PRAGMA busy_timeout=5000")
        try:
            yield conn
        finally:
            if conn.in_transaction:
                conn.rollback()
            conn.close()

    @contextmanager
    def transaction(self):
        with self.connection() as conn:
            try:
                conn.execute("BEGIN IMMEDIATE")
                yield conn
                conn.commit()
            except sqlite3.OperationalError as exc:
                raise PilotError(503, "database_unavailable") from exc

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as conn:
            journal = conn.execute("PRAGMA journal_mode=WAL").fetchone()[0]
            if journal.lower() != "wal":
                raise ValueError("WAL is required")
            conn.executescript(SCHEMA)
        self.path.chmod(0o600)

    def provision_slot(self, slot_id: str, profile: dict, *, reward: int,
                       worker_a: int = 10, worker_b: int = 20, funder: int = 7,
                       verifier_principal: int = 30) -> None:
        identifier(slot_id)
        validate_profile(profile)
        for value in (worker_a, worker_b, verifier_principal):
            bounded(value, minimum=1)
        if len({worker_a, worker_b, verifier_principal}) != 3:
            raise ValueError("two workers and the configured verifier must be distinct")
        bounded(reward, minimum=1)
        bounded(funder)
        bounded(reward + funder)
        cfg = RewardConfig(codec.binding(profile_binding(profile)), reward, worker_a, worker_b)
        config_json = canonical({"reward": codec.encode(cfg),
                                 "verifier_principal": verifier_principal}).decode()
        profile_json = canonical(profile).decode()
        state_json = canonical(codec.encode(initial_reward(cfg, funder=funder))).decode()
        with self.transaction() as conn:
            conn.execute(
                "INSERT INTO slots(slot_id,config_json,config_sha256,profile_json,"
                "profile_sha256,state_json,version) VALUES(?,?,?,?,?,?,0)",
                (slot_id, config_json, digest(config_json.encode()), profile_json,
                 digest(profile_json.encode()), state_json),
            )

    def provision_credential(self, token: str, principal: int, role: str,
                             slots: list[str]) -> None:
        hashed = token_digest(token)
        bounded(principal, minimum=1)
        if role not in ("worker", "verifier") or type(slots) is not list or not slots:
            raise ValueError("an explicit role and nonempty slot scope are required")
        if len(slots) != len(set(slots)):
            raise ValueError("duplicate scope")
        for slot_id in slots:
            identifier(slot_id)
        with self.transaction() as conn:
            for slot_id in slots:
                row = self._slot(conn, slot_id)
                cfg = codec.reward_config(json.loads(row["config_json"])["reward"])
                if role == "worker" and principal not in (cfg.workerA, cfg.workerB):
                    raise ValueError("worker credential does not name a configured worker")
                if role == "verifier" and principal in (cfg.workerA, cfg.workerB):
                    raise ValueError("verifier and worker principals must be distinct")
            conn.execute("INSERT INTO credentials VALUES(?,?,?,1,0)", (hashed, principal, role))
            conn.executemany("INSERT INTO credential_scopes VALUES(?,?)",
                             [(hashed, slot) for slot in slots])

    def set_credential_enabled(self, token: str, enabled: bool) -> None:
        if type(enabled) is not bool:
            raise ValueError("enabled must be boolean")
        hashed = token_digest(token)
        with self.transaction() as conn:
            row = conn.execute("SELECT enabled,epoch FROM credentials WHERE token_hash=?",
                               (hashed,)).fetchone()
            if row is None:
                raise ValueError("unknown credential")
            if row["enabled"] != int(enabled):
                bounded(row["epoch"] + 1)
                conn.execute("UPDATE credentials SET enabled=?,epoch=epoch+1 WHERE token_hash=?",
                             (int(enabled), hashed))

    def revoke_credential(self, token: str) -> None:
        self.set_credential_enabled(token, False)

    @staticmethod
    def _authorize(conn, hashed: str, slot_id: str, role: str | None = None):
        row = conn.execute("SELECT * FROM credentials WHERE token_hash=?", (hashed,)).fetchone()
        if row is None or not hmac.compare_digest(row["token_hash"], hashed):
            raise PilotError(401, "unauthorized")
        if not row["enabled"] or (role is not None and row["role"] != role):
            raise PilotError(403, "forbidden")
        scope = conn.execute("SELECT 1 FROM credential_scopes WHERE token_hash=? AND slot_id=?",
                             (hashed, slot_id)).fetchone()
        if scope is None:
            raise PilotError(403, "forbidden")
        configured = json.loads(Store._slot(conn, slot_id)["config_json"])
        if row["role"] == "verifier" and row["principal"] != configured["verifier_principal"]:
            raise PilotError(403, "forbidden")
        return row

    @staticmethod
    def _slot(conn, slot_id: str):
        row = conn.execute("SELECT * FROM slots WHERE slot_id=?", (slot_id,)).fetchone()
        if row is None:
            raise PilotError(404, "unknown_slot")
        if (digest(row["config_json"].encode()) != row["config_sha256"]
                or digest(row["profile_json"].encode()) != row["profile_sha256"]):
            raise PilotError(503, "stored_identity_mismatch")
        return row

    @staticmethod
    def _request(conn, principal: int, slot_id: str, operation: str, body: dict):
        request_id = identifier(body["request_id"])
        hashed = digest(canonical({"operation": operation, "slot_id": slot_id, "body": body}))
        row = conn.execute("SELECT * FROM requests WHERE principal=? AND request_id=?",
                           (principal, request_id)).fetchone()
        if row is not None:
            if row["request_sha256"] != hashed:
                raise PilotError(409, "request_conflict")
            return request_id, hashed, Reply(row["status_code"], json.loads(row["response_json"]))
        return request_id, hashed, None

    @staticmethod
    def _save_reply(conn, principal, request_id, request_sha256, slot_id, operation, reply):
        conn.execute("INSERT INTO requests VALUES(?,?,?,?,?,?,?)",
                     (principal, request_id, request_sha256, operation, slot_id,
                      reply.status, canonical(reply.body).decode()))
        return reply

    @staticmethod
    def _view(conn, row) -> dict:
        settlement = conn.execute("SELECT receipt_json FROM settlements WHERE slot_id=?",
                                  (row["slot_id"],)).fetchone()
        state = json.loads(row["state_json"])
        view = {"slot_id": row["slot_id"], "version": row["version"], "state": state,
                "settlement": json.loads(settlement[0]) if settlement else None}
        if state["phase"] == RewardPhase.REJECTED:
            refund = conn.execute("SELECT receipt_json FROM refunds WHERE slot_id=?",
                                  (row["slot_id"],)).fetchone()
            if refund is None or settlement is not None:
                raise PilotError(503, "kernel_invariant_failed")
            view["refund"] = json.loads(refund[0])
        return view

    def _terminal_reply(self, conn, row, state):
        if state.phase == RewardPhase.ACCEPTED:
            return Reply(200, self._view(conn, row))
        if state.phase == RewardPhase.REJECTED:
            return Reply(422, {"error": "proof_refused", **self._view(conn, row)})
        return None

    def status(self, token: str, slot_id: str) -> Reply:
        identifier(slot_id)
        with self.transaction() as conn:
            self._authorize(conn, token_digest(token), slot_id)
            return Reply(200, self._view(conn, self._slot(conn, slot_id)))

    def _worker_operation(self, token: str, slot_id: str, operation: str, body: dict) -> Reply:
        identifier(slot_id)
        artifact = None
        if operation == "lease":
            exact_fields(body, ("request_id", "ttl_ms"))
            bounded(body["ttl_ms"], minimum=1, maximum=MAX_TTL_MS)
        elif operation == "submit":
            exact_fields(body, ("request_id", "generation", "artifact_base64"))
            bounded(body["generation"], minimum=1)
            encoded = body["artifact_base64"]
            if type(encoded) is not str or len(encoded) > ((MAX_ARTIFACT + 2) // 3) * 4:
                raise PilotError(400, "invalid_artifact")
            try:
                artifact = base64.b64decode(encoded, validate=True)
            except (binascii.Error, ValueError) as exc:
                raise PilotError(400, "invalid_artifact") from exc
            if not 0 < len(artifact) <= MAX_ARTIFACT or base64.b64encode(artifact).decode() != encoded:
                raise PilotError(400, "invalid_artifact")
        else:
            raise ValueError("unknown worker operation")
        identifier(body["request_id"])
        with self.transaction() as conn:
            auth = self._authorize(conn, token_digest(token), slot_id, "worker")
            row = self._slot(conn, slot_id)
            request_id, hashed, existing = self._request(conn, auth["principal"], slot_id, operation, body)
            if existing is not None:
                return existing
            cfg = codec.reward_config(json.loads(row["config_json"])["reward"])
            old = codec.reward_state(json.loads(row["state_json"]))
            if old.phase == RewardPhase.REJECTED:
                return self._save_reply(conn, auth["principal"], request_id, hashed, slot_id,
                                        operation, Reply(409, {"error": "transition_refused"}))
            now = max(old.now, bounded(self.clock_ms()))
            state = reward_step(cfg, old, Tick(now - old.now))
            if operation == "lease":
                bounded(state.generation + 1)
                deadline = bounded(now + body["ttl_ms"])
                action = Lease(auth["principal"], deadline)
            else:
                action = Submit(auth["principal"], body["generation"], cfg.expected,
                                int(digest(artifact), 16))
            next_state = reward_step(cfg, state, action)
            if next_state is state:
                return self._save_reply(conn, auth["principal"], request_id, hashed, slot_id,
                                        operation, Reply(409, {"error": "transition_refused"}))
            version = bounded(row["version"] + 1)
            if operation == "submit":
                candidate_sha = digest(canonical(codec.encode(next_state.candidate)))
                conn.execute("UPDATE slots SET state_json=?,version=?,artifact=?,artifact_sha256=?,"
                             "candidate_sha256=? WHERE slot_id=? AND version=?",
                             (canonical(codec.encode(next_state)).decode(), version, artifact,
                              digest(artifact), candidate_sha, slot_id, row["version"]))
            else:
                conn.execute("UPDATE slots SET state_json=?,version=? WHERE slot_id=? AND version=?",
                             (canonical(codec.encode(next_state)).decode(), version, slot_id, row["version"]))
            reply = Reply(200, self._view(conn, self._slot(conn, slot_id)))
            return self._save_reply(conn, auth["principal"], request_id, hashed, slot_id, operation, reply)

    def lease(self, token: str, slot_id: str, body: dict) -> Reply:
        return self._worker_operation(token, slot_id, "lease", body)

    def submit(self, token: str, slot_id: str, body: dict) -> Reply:
        return self._worker_operation(token, slot_id, "submit", body)

    def prepare_verification(self, token: str, slot_id: str, body: dict) -> PreparedVerification | Reply:
        identifier(slot_id)
        exact_fields(body, ("request_id",))
        identifier(body["request_id"])
        with self.transaction() as conn:
            hashed_token = token_digest(token)
            auth = self._authorize(conn, hashed_token, slot_id, "verifier")
            row = self._slot(conn, slot_id)
            request_id, request_hash, existing = self._request(conn, auth["principal"], slot_id, "verify", body)
            if existing is not None:
                return existing
            state = codec.reward_state(json.loads(row["state_json"]))
            terminal = self._terminal_reply(conn, row, state)
            if terminal is not None:
                return self._save_reply(conn, auth["principal"], request_id, request_hash, slot_id,
                                        "verify", terminal)
            if state.phase != RewardPhase.SUBMITTED or state.candidate is None:
                return self._save_reply(conn, auth["principal"], request_id, request_hash, slot_id,
                                        "verify", Reply(409, {"error": "transition_refused"}))
            artifact = bytes(row["artifact"])
            candidate_json = canonical(codec.encode(state.candidate)).decode()
            if (digest(artifact) != row["artifact_sha256"]
                    or digest(candidate_json.encode()) != row["candidate_sha256"]
                    or state.candidate.artifact != int(row["artifact_sha256"], 16)):
                raise PilotError(503, "stored_identity_mismatch")
            return PreparedVerification(
                slot_id, row["version"], auth["principal"], hashed_token, auth["epoch"],
                request_id, request_hash, row["profile_json"], row["profile_sha256"],
                row["config_sha256"], candidate_json, row["candidate_sha256"],
                row["artifact_sha256"], artifact,
            )

    def _current_prepared(self, conn, prepared: PreparedVerification):
        auth = self._authorize(conn, prepared.token_hash, prepared.slot_id, "verifier")
        if auth["principal"] != prepared.principal or auth["epoch"] != prepared.credential_epoch:
            raise PilotError(409, "stale_verification")
        row = self._slot(conn, prepared.slot_id)
        existing = conn.execute("SELECT * FROM requests WHERE principal=? AND request_id=?",
                                (prepared.principal, prepared.request_id)).fetchone()
        if existing is not None:
            if existing["request_sha256"] != prepared.request_sha256:
                raise PilotError(409, "request_conflict")
            return row, Reply(existing["status_code"], json.loads(existing["response_json"]))
        state = codec.reward_state(json.loads(row["state_json"]))
        if (row["profile_sha256"] != prepared.profile_sha256
                or row["config_sha256"] != prepared.config_sha256
                or row["candidate_sha256"] != prepared.candidate_sha256
                or row["artifact_sha256"] != prepared.artifact_sha256
                or canonical(codec.encode(state.candidate)).decode() != prepared.candidate_json
                or row["artifact"] != prepared.artifact):
            raise PilotError(409, "stale_verification")
        terminal = self._terminal_reply(conn, row, state)
        if terminal is not None:
            # A new request racing closure observes the winner and gets its own
            # permanent binding without creating another financial effect.
            return row, self._save_reply(conn, prepared.principal, prepared.request_id,
                                         prepared.request_sha256, prepared.slot_id, "verify", terminal)
        if row["version"] != prepared.version or state.phase != RewardPhase.SUBMITTED:
            raise PilotError(409, "stale_verification")
        return row, None

    def record_verification_failure(self, prepared: PreparedVerification, error: PilotError) -> Reply:
        with self.transaction() as conn:
            _row, existing = self._current_prepared(conn, prepared)
            if existing is not None:
                return existing
            return self._save_reply(conn, prepared.principal, prepared.request_id,
                                    prepared.request_sha256, prepared.slot_id, "verify",
                                    Reply(error.status, {"error": error.code}))

    def commit_verification(self, prepared: PreparedVerification, decision: CheckedExport | RejectedExport,
                            *, before_commit: Callable[[], None] | None = None,
                            after_commit: Callable[[], None] | None = None) -> Reply:
        if (not isinstance(decision, (CheckedExport, RejectedExport))
                or decision.profile_sha256 != prepared.profile_sha256
                or decision.artifact_sha256 != prepared.artifact_sha256):
            raise PilotError(422, "proof_refused")
        with self.transaction() as conn:
            row, existing = self._current_prepared(conn, prepared)
            if existing is not None:
                return existing
            cfg = codec.reward_config(json.loads(row["config_json"])["reward"])
            state = codec.reward_state(json.loads(row["state_json"]))
            candidate = codec.candidate(json.loads(prepared.candidate_json))
            rejecting = isinstance(decision, RejectedExport)
            if rejecting == matches_export(prepared.profile, prepared.artifact):
                raise PilotError(503, "decision_evidence_mismatch")
            if rejecting:
                next_state = reject_reward(cfg, state, candidate)
            else:
                next_state = reward_step(cfg, state, Accept(True, candidate))
            if next_state is state:
                raise PilotError(409, "transition_refused")
            if next_state.total != state.total or next_state.payouts != (0 if rejecting else 1):
                raise PilotError(503, "kernel_invariant_failed")

            version = bounded(row["version"] + 1)
            kind = "refund" if rejecting else "settlement"
            domain = f"research-exchange/local-{kind}/v1"
            effect_id = digest(canonical({"domain": domain, "slot": prepared.slot_id,
                                          "candidate": prepared.candidate_sha256,
                                          "profile": prepared.profile_sha256}))
            receipt = {
                "schema": domain, f"{kind}_id": effect_id,
                "slot_id": prepared.slot_id, "candidate_sha256": prepared.candidate_sha256,
                "profile_sha256": prepared.profile_sha256, "artifact_sha256": prepared.artifact_sha256,
                "amount": cfg.reward, "before_version": row["version"], "version": version,
                "verifier_principal": prepared.principal,
                "credential_epoch": prepared.credential_epoch, "scope": "local-fixture-credits-only",
            }
            changed = conn.execute("UPDATE slots SET state_json=?,version=? WHERE slot_id=? AND version=?",
                                   (canonical(codec.encode(next_state)).decode(), version,
                                    prepared.slot_id, prepared.version))
            if changed.rowcount != 1:
                raise PilotError(409, "stale_verification")
            common = (prepared.slot_id, effect_id, prepared.candidate_sha256, prepared.profile_sha256)
            if rejecting:
                receipt["reason"] = "exact_export_mismatch"
                receipt["approved_artifact_sha256"] = prepared.profile["artifact_sha256"]
                receipt["destination"] = "original_slot_funder"
                conn.execute("INSERT INTO refunds VALUES(?,?,?,?,?,?,?,?)",
                             (*common, cfg.reward, row["version"], version, canonical(receipt).decode()))
            else:
                receipt["worker"] = candidate.worker
                receipt["verification"] = decision.receipt
                conn.execute("INSERT INTO settlements VALUES(?,?,?,?,?,?,?,?,?)",
                             (*common, candidate.worker, cfg.reward, row["version"], version,
                              canonical(receipt).decode()))
            reply = self._terminal_reply(conn, self._slot(conn, prepared.slot_id), next_state)
            self._save_reply(conn, prepared.principal, prepared.request_id,
                             prepared.request_sha256, prepared.slot_id, "verify", reply)
            if before_commit is not None:
                before_commit()
        if after_commit is not None:
            after_commit()
        return reply

    def inspect(self, slot_id: str) -> dict:
        """Trusted offline inspection; never expose credentials or token digests."""
        identifier(slot_id)
        with self.transaction() as conn:
            row = self._slot(conn, slot_id)
            view = self._view(conn, row)
            view["settlements"] = [dict(r) for r in conn.execute(
                "SELECT * FROM settlements WHERE slot_id=?", (slot_id,))]
            view["refunds"] = [dict(r) for r in conn.execute(
                "SELECT * FROM refunds WHERE slot_id=?", (slot_id,))]
            view["requests"] = [dict(r) for r in conn.execute(
                "SELECT * FROM requests WHERE slot_id=? ORDER BY principal,request_id", (slot_id,))]
            view["sqlite"] = {"version": sqlite3.sqlite_version,
                              "journal_mode": conn.execute("PRAGMA journal_mode").fetchone()[0],
                              "synchronous": conn.execute("PRAGMA synchronous").fetchone()[0],
                              "foreign_keys": conn.execute("PRAGMA foreign_keys").fetchone()[0]}
            return view
