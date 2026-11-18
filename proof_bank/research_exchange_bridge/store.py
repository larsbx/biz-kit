"""Durable admission and guarded controlled replay on a trusted local host.

No contributor-supplied command, profile, principal, verdict, or checker path is
accepted. The core's reward fields are disposable one-unit model fixtures; this
database neither issues credits nor writes Biz-kit financial history.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import hmac
import os
from pathlib import Path
import secrets
import sqlite3
import time

from .common import (BridgeError, CORE, MAX_ARTIFACT, MAX_ENTRIES, VERIFIER,
                     canonical, core_identity, digest, envelope, exact,
                     hexadecimal, integer, loads, require, sha, text, token_hash)
from . import model, source
from adapter_pilot.checker import CheckedExport, ControlledChecker, RejectedExport
from adapter_pilot.common import (POLICY, PilotError, canonical as profile_canonical,
                                  source_identity, validate_profile)


SCHEMA = """
CREATE TABLE IF NOT EXISTS bridge_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS bridge_libraries(
 id TEXT PRIMARY KEY,catalog_json TEXT NOT NULL,profile_json TEXT NOT NULL,
 profile_sha256 TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),
 epoch INTEGER NOT NULL CHECK(epoch>=0));
CREATE TABLE IF NOT EXISTS bridge_grants(
 token_hash TEXT PRIMARY KEY,principal TEXT NOT NULL,expires INTEGER NOT NULL,
 libraries_json TEXT NOT NULL,scopes_json TEXT NOT NULL,
 enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),epoch INTEGER NOT NULL CHECK(epoch>=0));
CREATE TABLE IF NOT EXISTS bridge_authority(
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),principal TEXT NOT NULL,
 enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),epoch INTEGER NOT NULL CHECK(epoch>=0));
CREATE TABLE IF NOT EXISTS bridge_submissions(
 id TEXT PRIMARY KEY,principal TEXT NOT NULL,library TEXT NOT NULL REFERENCES bridge_libraries(id),
 binding_json TEXT NOT NULL,artifact BLOB NOT NULL,receipt_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS bridge_jobs(
 id TEXT PRIMARY KEY,submission_id TEXT NOT NULL UNIQUE REFERENCES bridge_submissions(id),
 principal TEXT NOT NULL,request_token_hash TEXT NOT NULL REFERENCES bridge_grants(token_hash),
 request_epoch INTEGER NOT NULL,library_epoch INTEGER NOT NULL,
 binding_json TEXT NOT NULL,config_json TEXT NOT NULL,state_json TEXT NOT NULL,
 version INTEGER NOT NULL CHECK(version>=0),receipt_json TEXT NOT NULL,
 terminal INTEGER NOT NULL CHECK(terminal IN(0,1)));
CREATE TABLE IF NOT EXISTS bridge_requests(
 principal TEXT NOT NULL,request_id TEXT NOT NULL,request_sha256 TEXT NOT NULL,
 tool TEXT NOT NULL,receipt_json TEXT NOT NULL,PRIMARY KEY(principal,request_id));
CREATE TABLE IF NOT EXISTS bridge_outbox(
 job_id TEXT PRIMARY KEY REFERENCES bridge_jobs(id),
 status TEXT NOT NULL CHECK(status IN('pending','paused','complete')));
CREATE TABLE IF NOT EXISTS bridge_effects(
 job_id TEXT PRIMARY KEY REFERENCES bridge_jobs(id),kind TEXT NOT NULL,
 before_version INTEGER NOT NULL,after_version INTEGER NOT NULL,
 receipt_json TEXT NOT NULL,wire_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS bridge_attempts(
 id INTEGER PRIMARY KEY,job_id TEXT NOT NULL REFERENCES bridge_jobs(id),
 observation_json TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS bridge_library_immutable
BEFORE UPDATE OF id,catalog_json,profile_json,profile_sha256 ON bridge_libraries
BEGIN SELECT RAISE(ABORT,'immutable library'); END;
CREATE TRIGGER IF NOT EXISTS bridge_grant_identity_immutable
BEFORE UPDATE OF token_hash,principal,expires,libraries_json,scopes_json ON bridge_grants
BEGIN SELECT RAISE(ABORT,'immutable grant identity'); END;
CREATE TRIGGER IF NOT EXISTS bridge_submission_immutable BEFORE UPDATE ON bridge_submissions
BEGIN SELECT RAISE(ABORT,'immutable submission'); END;
CREATE TRIGGER IF NOT EXISTS bridge_submission_permanent BEFORE DELETE ON bridge_submissions
BEGIN SELECT RAISE(ABORT,'permanent submission'); END;
CREATE TRIGGER IF NOT EXISTS bridge_job_identity_immutable
BEFORE UPDATE OF id,submission_id,principal,request_token_hash,request_epoch,library_epoch,binding_json,config_json ON bridge_jobs
BEGIN SELECT RAISE(ABORT,'immutable job identity'); END;
CREATE TRIGGER IF NOT EXISTS bridge_terminal_immutable BEFORE UPDATE ON bridge_jobs WHEN OLD.terminal=1
BEGIN SELECT RAISE(ABORT,'immutable terminal job'); END;
CREATE TRIGGER IF NOT EXISTS bridge_job_permanent BEFORE DELETE ON bridge_jobs
BEGIN SELECT RAISE(ABORT,'permanent job'); END;
CREATE TRIGGER IF NOT EXISTS bridge_request_immutable BEFORE UPDATE ON bridge_requests
BEGIN SELECT RAISE(ABORT,'immutable request'); END;
CREATE TRIGGER IF NOT EXISTS bridge_request_permanent BEFORE DELETE ON bridge_requests
BEGIN SELECT RAISE(ABORT,'permanent request'); END;
CREATE TRIGGER IF NOT EXISTS bridge_effect_immutable BEFORE UPDATE ON bridge_effects
BEGIN SELECT RAISE(ABORT,'immutable effect'); END;
CREATE TRIGGER IF NOT EXISTS bridge_effect_permanent BEFORE DELETE ON bridge_effects
BEGIN SELECT RAISE(ABORT,'permanent effect'); END;
CREATE TRIGGER IF NOT EXISTS bridge_attempt_immutable BEFORE UPDATE ON bridge_attempts
BEGIN SELECT RAISE(ABORT,'immutable attempt'); END;
CREATE TRIGGER IF NOT EXISTS bridge_attempt_permanent BEFORE DELETE ON bridge_attempts
BEGIN SELECT RAISE(ABORT,'permanent attempt'); END;
CREATE TRIGGER IF NOT EXISTS bridge_outbox_permanent BEFORE DELETE ON bridge_outbox
BEGIN SELECT RAISE(ABORT,'permanent outbox'); END;
CREATE TRIGGER IF NOT EXISTS bridge_authority_permanent BEFORE DELETE ON bridge_authority
BEGIN SELECT RAISE(ABORT,'permanent authority'); END;
CREATE TRIGGER IF NOT EXISTS bridge_meta_immutable BEFORE UPDATE ON bridge_meta
BEGIN SELECT RAISE(ABORT,'immutable instance identity'); END;
CREATE TRIGGER IF NOT EXISTS bridge_meta_permanent BEFORE DELETE ON bridge_meta
BEGIN SELECT RAISE(ABORT,'permanent instance identity'); END;
"""


@dataclass(frozen=True)
class Prepared:
    job_id: str
    submission_id: str
    binding_json: str
    config_json: str
    profile_json: str
    profile_sha256: str
    artifact: bytes
    version: int
    authority_epoch: int
    requester_epoch: int
    library_epoch: int
    token_hash: str


class Store:
    def __init__(self, path, receipt_key: bytes, *, clock=None):
        require(Path(path).is_absolute() and str(path) != ":memory:", "invalid_configuration")
        require(type(receipt_key) is bytes and len(receipt_key) >= 32, "invalid_configuration")
        self.path = Path(path)
        self.key = receipt_key
        self.clock = clock or (lambda: int(time.time()))
        self.core = core_identity()

    @contextmanager
    def connection(self):
        connection = sqlite3.connect(self.path, isolation_level=None, timeout=2)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA busy_timeout=2000")
        try:
            yield connection
        except sqlite3.OperationalError as error:
            raise BridgeError("database_unavailable") from error
        finally:
            if connection.in_transaction:
                connection.rollback()
            connection.close()

    @contextmanager
    def transaction(self):
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()

    def initialize(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as connection:
            require(connection.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal",
                    "database_unavailable")
            connection.executescript(SCHEMA)
        self.path.chmod(0o600)
        values = {"schema": "research-exchange/durable-store/v1", "core": canonical(self.core).decode(),
                  "receipt_key_sha256": sha(self.key)}
        with self.transaction() as connection:
            for name, value in values.items():
                row = connection.execute("SELECT value FROM bridge_meta WHERE key=?", (name,)).fetchone()
                require(row is None or row[0] == value, "invalid_configuration")
                connection.execute("INSERT OR IGNORE INTO bridge_meta VALUES(?,?)", (name, value))
            connection.execute("INSERT OR IGNORE INTO bridge_authority VALUES(1,?,1,0)", (VERIFIER,))

    def provision_library(self, library: dict, profile: dict):
        exact(library, ("id", "engine", "revision", "snapshot_sha256", "environment_sha256",
                        "policy_sha256", "generation"), "invalid_configuration")
        require(text(library["id"]) and library["engine"] == "lean" and
                hexadecimal(library["revision"], 40) and integer(library["generation"], 1),
                "invalid_configuration")
        if source.is_source(profile):
            require(profile == source.profile_for(library["environment_sha256"], profile.get("policy")) and
                    library["revision"] == source.REVISION and
                    library["snapshot_sha256"] == profile["source_sha256"] and
                    library["policy_sha256"] == sha(profile_canonical(profile["policy"])),
                    "profile_identity_mismatch")
        else:
            validate_profile(profile)
            require(library["revision"] == self.core["revision"] and
                    library["snapshot_sha256"] == profile["source_sha256"] and
                    library["environment_sha256"] == profile["toolchain_lock_sha256"] and
                    library["policy_sha256"] == sha(profile_canonical(POLICY)) and
                    profile["source_files"] == source_identity(CORE), "profile_identity_mismatch")
        with self.transaction() as connection:
            connection.execute("INSERT INTO bridge_libraries VALUES(?,?,?,?,1,0)",
                               (library["id"], canonical(library).decode(),
                                profile_canonical(profile).decode(), sha(profile_canonical(profile))))

    def provision_grant(self, token, principal, libraries, scopes, expires):
        hashed = token_hash(token)
        require(text(principal) and principal != VERIFIER and integer(expires, 1) and
                type(libraries) is list and libraries and len(set(libraries)) == len(libraries) and
                all(text(x) for x in libraries) and type(scopes) is list and scopes and
                len(set(scopes)) == len(scopes) and set(scopes) <=
                {"library:read", "proof:submit", "verification:request"}, "invalid_configuration")
        require(not hmac.compare_digest(hashed, sha(self.key)), "invalid_configuration")
        with self.transaction() as connection:
            for library in libraries:
                require(connection.execute("SELECT 1 FROM bridge_libraries WHERE id=?", (library,)).fetchone()
                        is not None, "invalid_configuration")
            connection.execute("INSERT INTO bridge_grants VALUES(?,?,?,?,?,1,0)",
                               (hashed, principal, expires, canonical(libraries).decode(), canonical(scopes).decode()))

    def set_grant_enabled(self, token, enabled):
        require(type(enabled) is bool, "invalid_configuration")
        with self.transaction() as connection:
            row = connection.execute("SELECT * FROM bridge_grants WHERE token_hash=?", (token_hash(token),)).fetchone()
            require(row is not None, "not_found")
            if row["enabled"] != int(enabled):
                require(integer(row["epoch"] + 1), "capacity")
                connection.execute("UPDATE bridge_grants SET enabled=?,epoch=epoch+1 WHERE token_hash=?",
                                   (int(enabled), row["token_hash"]))

    def set_verifier_enabled(self, enabled):
        require(type(enabled) is bool, "invalid_configuration")
        with self.transaction() as connection:
            row = self._authority(connection)
            if row["enabled"] != int(enabled):
                require(integer(row["epoch"] + 1), "capacity")
                connection.execute("UPDATE bridge_authority SET enabled=?,epoch=epoch+1 WHERE singleton=1",
                                   (int(enabled),))

    def _authority(self, connection):
        row = connection.execute("SELECT * FROM bridge_authority WHERE singleton=1").fetchone()
        require(row is not None and row["principal"] == VERIFIER, "stored_identity_mismatch")
        return row

    def _grant(self, connection, hashed, scope=None, library=None):
        row = connection.execute("SELECT * FROM bridge_grants WHERE token_hash=?", (hashed,)).fetchone()
        require(row is not None and row["enabled"] == 1 and row["expires"] > self.clock(), "unauthorized")
        if scope:
            require(scope in loads(row["scopes_json"]), "forbidden")
        if library:
            require(library in loads(row["libraries_json"]), "forbidden")
        return row

    def authenticate(self, token):
        with self.connection() as connection:
            row = self._grant(connection, token_hash(token))
            return {"principal": row["principal"], "expires": row["expires"],
                    "libraries": loads(row["libraries_json"]), "scopes": loads(row["scopes_json"])}

    def _library(self, connection, library):
        row = connection.execute("SELECT * FROM bridge_libraries WHERE id=?", (library,)).fetchone()
        require(row is not None and row["enabled"] == 1, "forbidden")
        return row

    def _receipt(self, status, identity, binding, version, details, accepted=False, *, scope="exact-reviewed-export-only"):
        return envelope({"schema": "research-exchange/evidence/v1", "id": identity,
                         "status": status, "binding": binding, "recorded_at": self.clock(),
                         "state_version": version, "details": details,
                         "acceptance_scope": scope,
                         "mathematical_acceptance": accepted, "credit_issuance": False}, self.key)

    def _replay(self, connection, grant, tool, args):
        request_hash = digest("research-exchange/request/v1", {"tool": tool, "arguments": args})
        row = connection.execute("SELECT * FROM bridge_requests WHERE principal=? AND request_id=?",
                                 (grant["principal"], args["idempotency_key"])).fetchone()
        if row is not None:
            require(row["request_sha256"] == request_hash, "idempotency_conflict")
            return loads(row["receipt_json"]), request_hash
        require(connection.execute("SELECT count(*) FROM bridge_requests").fetchone()[0] < MAX_ENTRIES * 2,
                "capacity")
        return None, request_hash

    def _remember(self, connection, grant, tool, args, request_hash, receipt):
        connection.execute("INSERT INTO bridge_requests VALUES(?,?,?,?,?)",
                           (grant["principal"], args["idempotency_key"], request_hash,
                            tool, canonical(receipt).decode()))

    def call(self, token, tool, args):
        require(type(tool) is str and type(args) is dict)
        hashed = token_hash(token)
        with self.transaction() as connection:
            grant = self._grant(connection, hashed)
            if tool == "library_discover":
                exact(args, ())
                self._grant(connection, hashed, "library:read")
                libraries = [loads(row[0]) for row in connection.execute(
                    "SELECT catalog_json FROM bridge_libraries WHERE enabled=1 ORDER BY id")
                    if loads(row[0])["id"] in loads(grant["libraries_json"])]
                return {"libraries": libraries, "core": self.core,
                        "execution": "durable-exact-reviewed-export-only",
                        "benefits": {"purpose": "nonprofit-open-source-research", "recognition": "proposed",
                                     "ecosystem_credits": "nonmonetary-policy-pending", "issuance_enabled": False}}
            if tool == "proof_submit":
                return self._submit(connection, grant, hashed, args)
            if tool == "verification_request":
                return self._request(connection, grant, hashed, args)
            if tool == "receipt_get":
                exact(args, ("id",))
                require(hexadecimal(args["id"]))
                self._grant(connection, hashed, "library:read")
                row = connection.execute("SELECT principal,library,receipt_json FROM bridge_submissions WHERE id=?",
                                         (args["id"],)).fetchone()
                if row is None:
                    row = connection.execute("SELECT j.principal,s.library,j.receipt_json FROM bridge_jobs j "
                                             "JOIN bridge_submissions s ON s.id=j.submission_id WHERE j.id=?",
                                             (args["id"],)).fetchone()
                require(row is not None and row["principal"] == grant["principal"], "not_found")
                self._grant(connection, hashed, library=row["library"])
                self._library(connection, row["library"])
                return loads(row["receipt_json"])
            raise BridgeError("unknown_tool")

    def _submit(self, connection, grant, hashed, args):
        exact(args, ("idempotency_key", "library", "revision", "snapshot_sha256", "generation",
                     "target", "artifact", "artifact_sha256"))
        require(text(args["library"]) and text(args["idempotency_key"]) and text(args["target"]) and
                text(args["artifact"], MAX_ARTIFACT), "invalid_or_stale_binding")
        self._grant(connection, hashed, "proof:submit", args["library"])
        library = self._library(connection, args["library"])
        catalog, profile = loads(library["catalog_json"]), loads(library["profile_json"])
        artifact = args["artifact"].encode("utf-8")
        require(args["revision"] == catalog["revision"] and args["snapshot_sha256"] == catalog["snapshot_sha256"] and
                integer(args["generation"], 1) and args["generation"] == catalog["generation"] and
                args["target"] == profile["theorem"] and args["artifact_sha256"] == sha(artifact),
                "invalid_or_stale_binding")
        scope = "exact-reviewed-export-only"
        if source.is_source(profile):
            try:
                source.materialize(artifact)
            except BridgeError as error:
                raise BridgeError("invalid_or_stale_binding") from error
            scope = source.SCOPE
        previous, request_hash = self._replay(connection, grant, "proof_submit", args)
        if previous:
            return previous
        require(connection.execute("SELECT count(*) FROM bridge_submissions").fetchone()[0] < MAX_ENTRIES, "capacity")
        binding = {"contributor": grant["principal"], "library": catalog["id"], "engine": "lean",
                   "source_revision": catalog["revision"], "source_snapshot_sha256": catalog["snapshot_sha256"],
                   "generation": catalog["generation"], "target": args["target"],
                   "artifact_sha256": sha(artifact), "environment_sha256": catalog["environment_sha256"],
                   "policy_sha256": catalog["policy_sha256"], "core": self.core}
        identity = digest("research-exchange/durable-submission/v1",
                          {"nonce": secrets.token_hex(32), "binding": binding})
        receipt = self._receipt("submitted", identity, binding, 0, {"storage": "sqlite-immutable-artifact"}, scope=scope)
        connection.execute("INSERT INTO bridge_submissions VALUES(?,?,?,?,?,?)",
                           (identity, grant["principal"], catalog["id"], canonical(binding).decode(), artifact,
                            canonical(receipt).decode()))
        self._remember(connection, grant, "proof_submit", args, request_hash, receipt)
        return receipt

    @staticmethod
    def _flat(binding):
        flat = {key: value for key, value in binding.items() if key not in ("core", "submission_id")}
        flat["core_revision"] = binding["core"]["revision"]
        flat["core_source_sha256"] = binding["core"]["source_manifest_sha256"]
        return flat

    def _request(self, connection, grant, hashed, args):
        exact(args, ("idempotency_key", "submission_id"))
        require(text(args["idempotency_key"]) and hexadecimal(args["submission_id"]))
        sub = connection.execute("SELECT * FROM bridge_submissions WHERE id=?", (args["submission_id"],)).fetchone()
        require(sub is not None and sub["principal"] == grant["principal"], "not_found")
        self._grant(connection, hashed, "verification:request", sub["library"])
        library = self._library(connection, sub["library"])
        authority = self._authority(connection)
        require(authority["enabled"] == 1, "stale_authority")
        previous, request_hash = self._replay(connection, grant, "verification_request", args)
        if previous:
            return previous
        require(connection.execute("SELECT 1 FROM bridge_jobs WHERE submission_id=?", (sub["id"],)).fetchone()
                is None, "already_requested")
        require(connection.execute("SELECT count(*) FROM bridge_jobs").fetchone()[0] < MAX_ENTRIES, "capacity")
        binding = {**loads(sub["binding_json"]), "submission_id": sub["id"]}
        flat = self._flat(binding)
        config = {"expected": flat, "profile": library["profile_sha256"], "verifier": authority["principal"], "reward": 1}
        state = model.initial(flat, authority["epoch"], grant["epoch"])
        identity = digest("research-exchange/durable-job/v1", {"binding": binding, "nonce": secrets.token_hex(32)})
        source_profile = source.is_source(loads(library["profile_json"]))
        scope = source.SCOPE if source_profile else "exact-reviewed-export-only"
        reservation = "durable-source-slot" if source_profile else "durable-reviewed-export-slot"
        receipt = self._receipt("queued", identity, binding, 0,
                                {"reservation": reservation, "profile_sha256": library["profile_sha256"],
                                 "credits_issued": 0}, scope=scope)
        connection.execute("INSERT INTO bridge_jobs VALUES(?,?,?,?,?,?,?,?,?,?,?,0)",
                           (identity, sub["id"], grant["principal"], hashed, grant["epoch"], library["epoch"],
                            canonical(binding).decode(), canonical(config).decode(), canonical(state).decode(), 0,
                            canonical(receipt).decode()))
        connection.execute("INSERT INTO bridge_outbox VALUES(?,'pending')", (identity,))
        self._remember(connection, grant, "verification_request", args, request_hash, receipt)
        return receipt

    def pending(self, *, include_source=True):
        with self.connection() as connection:
            rows = connection.execute(
                "SELECT o.job_id,l.profile_json FROM bridge_outbox o JOIN bridge_jobs j ON j.id=o.job_id "
                "JOIN bridge_submissions s ON s.id=j.submission_id JOIN bridge_libraries l ON l.id=s.library "
                "WHERE o.status='pending' ORDER BY o.job_id")
            return [row[0] for row in rows if include_source or not source.is_source(loads(row[1]))]

    def _joined(self, connection, job_id):
        row = connection.execute("SELECT * FROM bridge_jobs WHERE id=?", (job_id,)).fetchone()
        require(row is not None, "not_found")
        sub = connection.execute("SELECT * FROM bridge_submissions WHERE id=?", (row["submission_id"],)).fetchone()
        grant = self._grant(connection, row["request_token_hash"], "verification:request", sub["library"])
        require(grant["principal"] == row["principal"] and grant["epoch"] == row["request_epoch"], "stale_authority")
        library = self._library(connection, sub["library"])
        require(library["epoch"] == row["library_epoch"], "stale_authority")
        authority = self._authority(connection)
        require(authority["enabled"] == 1, "stale_authority")
        binding = loads(row["binding_json"])
        config = loads(row["config_json"])
        profile = loads(library["profile_json"])
        catalog = loads(library["catalog_json"])
        state = loads(row["state_json"])
        require({**loads(sub["binding_json"]), "submission_id": sub["id"]} == binding and
                binding["contributor"] == row["principal"] and binding["core"] == self.core and
                binding["artifact_sha256"] == sha(bytes(sub["artifact"])) and
                config["expected"] == self._flat(binding) == state["binding"] and
                state["version"] == row["version"] and config["profile"] == library["profile_sha256"] ==
                sha(profile_canonical(profile)) and config["verifier"] == authority["principal"] and
                binding["source_revision"] == catalog["revision"] and
                binding["source_snapshot_sha256"] == catalog["snapshot_sha256"] == profile["source_sha256"] and
                binding["target"] == profile["theorem"] and binding["generation"] == catalog["generation"] and
                binding["environment_sha256"] == catalog["environment_sha256"] == profile["toolchain_lock_sha256"] and
                binding["policy_sha256"] == catalog["policy_sha256"] == sha(profile_canonical(profile["policy"])),
                "stored_identity_mismatch")
        # These fields represent a fresh transaction join, not cached job authority.
        state.update(verifier_enabled=bool(authority["enabled"]), authority_epoch=authority["epoch"],
                     requester_enabled=bool(grant["enabled"]), requester_epoch=grant["epoch"])
        return row, sub, grant, library, authority, binding, config, profile, state

    def prepare(self, job_id):
        require(hexadecimal(job_id))
        with self.transaction() as connection:
            row, sub, grant, library, authority, binding, config, profile, state = self._joined(connection, job_id)
            require(row["terminal"] == 0, "conflict")
            return Prepared(job_id, sub["id"], row["binding_json"], row["config_json"], library["profile_json"],
                            library["profile_sha256"], bytes(sub["artifact"]), row["version"], authority["epoch"],
                            grant["epoch"], library["epoch"], row["request_token_hash"])

    def commit(self, prepared: Prepared, checked, *, failpoint=None):
        require(type(checked) in (CheckedExport, RejectedExport, source.CheckedSource), "checker_inconclusive")
        with self.transaction() as connection:
            row, sub, grant, library, authority, binding, config, profile, state = self._joined(connection, prepared.job_id)
            require(prepared.submission_id == row["submission_id"] and prepared.binding_json == row["binding_json"] and
                    prepared.config_json == row["config_json"] and prepared.profile_json == library["profile_json"] and
                    prepared.profile_sha256 == library["profile_sha256"] == checked.profile_sha256 and
                    prepared.artifact == bytes(sub["artifact"]) and checked.artifact_sha256 == sha(prepared.artifact) and
                    prepared.token_hash == row["request_token_hash"], "stored_identity_mismatch")
            require(prepared.authority_epoch == authority["epoch"] and
                    prepared.requester_epoch == grant["epoch"] and prepared.library_epoch == library["epoch"], "stale_authority")
            source_profile = source.is_source(profile)
            require(source_profile == (type(checked) is source.CheckedSource), "checker_inconclusive")
            if source_profile:
                source.validate_evidence(checked.receipt, binding, profile, prepared.artifact)
            if row["terminal"]:
                return loads(row["receipt_json"])
            require(prepared.version == row["version"], "stale_version")
            require(integer(row["version"] + 1), "capacity")
            verdict = "rejected" if type(checked) is RejectedExport else "accepted"
            wire = {"config": config, "state": state,
                    "identity": {"authenticated": True, "principal": authority["principal"], "requester": grant["principal"]},
                    "prepared": {"binding": self._flat(loads(prepared.binding_json)), "profile": prepared.profile_sha256,
                                 "version": prepared.version, "authority_epoch": prepared.authority_epoch,
                                 "requester_epoch": prepared.requester_epoch, "checked": True}, "verdict": verdict}
            decision = model.decide(wire)
            require(decision["ready"] and decision["state"]["phase"] == verdict and
                    decision["projected"] == decision["core_result"], "stored_identity_mismatch")
            details = {"profile_sha256": prepared.profile_sha256, "credits_issued": 0,
                       "fixture_effect": "one-local-unit-" + ("settlement" if verdict == "accepted" else "refund"),
                       "controlled_check": checked.receipt if verdict == "accepted" else
                       {"status": "rejected", "scope": "exact-reviewed-export-only", "reason": "export_profile_mismatch"}}
            scope = source.SCOPE if source_profile else "exact-reviewed-export-only"
            receipt = self._receipt(verdict, row["id"], binding, row["version"] + 1, details,
                                    verdict == "accepted", scope=scope)
            connection.execute("UPDATE bridge_jobs SET state_json=?,version=version+1,receipt_json=?,terminal=1 WHERE id=?",
                               (canonical(decision["state"]).decode(), canonical(receipt).decode(), row["id"]))
            connection.execute("INSERT INTO bridge_effects VALUES(?,?,?,?,?,?)",
                               (row["id"], verdict, row["version"], row["version"] + 1,
                                canonical(receipt).decode(), canonical(wire).decode()))
            connection.execute("UPDATE bridge_outbox SET status='complete' WHERE job_id=?", (row["id"],))
            connection.execute("INSERT INTO bridge_attempts(job_id,observation_json) VALUES(?,?)",
                               (row["id"], canonical(details).decode()))
            if failpoint == "before_commit":
                os._exit(86)
        if failpoint == "after_commit":
            os._exit(87)
        return receipt

    def pause(self, job_id, code, *, stage=None):
        """Record an unsuccessful attempt without changing represented kernel state."""
        with self.transaction() as connection:
            row = connection.execute("SELECT * FROM bridge_jobs WHERE id=?", (job_id,)).fetchone()
            if row is None or row["terminal"]:
                return
            details = {"status": "inconclusive", "reason": code, "credits_issued": 0}
            if stage is not None:
                details["stage"] = stage
            scope = loads(row["receipt_json"])["payload"]["acceptance_scope"]
            receipt = self._receipt("verification_inconclusive", job_id, loads(row["binding_json"]),
                                    row["version"], details, scope=scope)
            connection.execute("UPDATE bridge_jobs SET receipt_json=? WHERE id=?", (canonical(receipt).decode(), job_id))
            connection.execute("UPDATE bridge_outbox SET status='paused' WHERE job_id=?", (job_id,))
            connection.execute("INSERT INTO bridge_attempts(job_id,observation_json) VALUES(?,?)", (job_id, canonical(details).decode()))

    def retry(self, job_id):
        """Trusted operator retry, never an MCP tool; original grant must remain live."""
        with self.transaction() as connection:
            row, *_ = self._joined(connection, job_id)
            require(row["terminal"] == 0, "conflict")
            connection.execute("UPDATE bridge_outbox SET status='pending' WHERE job_id=?", (job_id,))

    def execute_one(self, job_id, lean_root, *, source_root=None, failpoint=None, pause_path=None):
        try:
            prepared = self.prepare(job_id)
            checker = ControlledChecker(Path(lean_root))
            profile = loads(prepared.profile_json)
            if source.is_source(profile):
                checked = source.check_source(checker, source_root, profile, prepared.artifact,
                                              loads(prepared.binding_json), prepared.profile_sha256)
            else:
                checked = checker.check(profile, prepared.artifact)
            if pause_path:
                base = Path(pause_path)
                base.with_suffix(base.suffix + ".ready").write_text(job_id)
                deadline = time.monotonic() + 20
                while not base.with_suffix(base.suffix + ".release").exists():
                    require(time.monotonic() < deadline, "checker_unavailable")
                    time.sleep(0.05)
            return self.commit(prepared, checked, failpoint=failpoint)
        except source.SourceStageError as error:
            self.pause(job_id, error.code, stage=error.stage)
            return None
        except (BridgeError, PilotError) as error:
            self.pause(job_id, error.code)
            return None
        except (OSError, ValueError) as error:
            self.pause(job_id, "checker_unavailable")
            return None

    def inspect(self, job_id):
        """Trusted offline evidence API; never exposes bearer tokens or token hashes."""
        with self.connection() as connection:
            row = connection.execute("SELECT state_json,version,receipt_json,terminal,request_token_hash FROM bridge_jobs WHERE id=?", (job_id,)).fetchone()
            require(row is not None, "not_found")
            stored_state = loads(row["state_json"])
            authority = self._authority(connection)
            grant = connection.execute("SELECT enabled,epoch,expires FROM bridge_grants WHERE token_hash=?",
                                       (row["request_token_hash"],)).fetchone()
            represented_state = {**stored_state, "verifier_enabled": bool(authority["enabled"]),
                                 "authority_epoch": authority["epoch"],
                                 "requester_enabled": bool(grant["enabled"]) and grant["expires"] > self.clock(),
                                 "requester_epoch": grant["epoch"]}
            return {"state": stored_state, "represented_state": represented_state,
                    "authority_fields": "fresh transaction join is required; state contains the last stored job snapshot",
                    "version": row["version"], "terminal": bool(row["terminal"]),
                    "receipt": loads(row["receipt_json"]),
                    "effects": [dict(effect) for effect in connection.execute(
                        "SELECT kind,before_version,after_version,receipt_json,wire_json FROM bridge_effects WHERE job_id=?", (job_id,))],
                    "outbox": connection.execute("SELECT status FROM bridge_outbox WHERE job_id=?", (job_id,)).fetchone()[0],
                    "attempts": [loads(attempt[0]) for attempt in connection.execute(
                        "SELECT observation_json FROM bridge_attempts WHERE job_id=? ORDER BY id", (job_id,))],
                    "sqlite": {"journal_mode": connection.execute("PRAGMA journal_mode").fetchone()[0],
                               "synchronous": connection.execute("PRAGMA synchronous").fetchone()[0],
                               "foreign_keys": connection.execute("PRAGMA foreign_keys").fetchone()[0]}}
