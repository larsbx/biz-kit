"""Disposable single-slot MCP admission and offline controlled replay."""
from __future__ import annotations

import argparse
from contextlib import closing, contextmanager
import hmac
import json
import os
from pathlib import Path
import sqlite3
import struct
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
CORE_ROOT = ROOT.parent / "research_exchange"
sys.path.insert(0, str(CORE_ROOT))

from adapter_pilot.checker import ControlledChecker, RejectedExport
from adapter_pilot.common import (
    PilotError, canonical, digest, exact_fields, parse_json, profile_binding,
    source_identity, token_digest, validate_profile,
)
from reference.kernel import Binding, Lease, RewardConfig, Submit, Tick, initial_reward, reward_step

CORE = json.loads((ROOT / "CORE_SNAPSHOT.json").read_bytes())
LIBRARY = "reviewed-lean-export"
SUBMIT_FIELDS = ("idempotency_key", "library", "revision", "snapshot_sha256",
                 "generation", "target", "artifact", "artifact_sha256")
MAX_ARTIFACT = 65_536
MAX_PACKET = 262_144


def commitment(domain, value):
    return digest(b"research-exchange/durable/" + domain.encode("ascii") + b"\n" + canonical(value))


def library(profile):
    return {
        "id": LIBRARY, "engine": "lean", "revision": CORE["revision"],
        "snapshot_sha256": profile["source_sha256"],
        "environment_sha256": profile["toolchain_lock_sha256"],
        "policy_sha256": f'{profile_binding(profile)["policy"]:064x}',
        "target": profile["theorem"], "generation": 1,
        "profile_sha256": digest(canonical(profile)),
    }


def receipt(status, identity, binding, details=None):
    return {
        "schema": "research-exchange/durable-evidence/v1",
        "id": identity, "status": status, "binding": binding,
        "details": details or {}, "mathematical_acceptance": False,
        "credit_issuance": False,
    }


class Store:
    def __init__(self, path):
        self.path = Path(path).resolve()

    @contextmanager
    def transaction(self, *, create=False, read_only=False):
        mode = "rwc" if create else "rw"
        with closing(sqlite3.connect(f"{self.path.as_uri()}?mode={mode}", uri=True, timeout=3)) as db:
            with db:
                db.row_factory = sqlite3.Row
                db.execute("PRAGMA foreign_keys=ON")
                db.execute("PRAGMA synchronous=FULL")
                if create:
                    db.execute("PRAGMA journal_mode=WAL")
                db.execute("BEGIN" if read_only else "BEGIN IMMEDIATE")
                yield db

    def provision(self, profile, token, expires):
        validate_profile(profile)
        if profile["source_files"] != source_identity(CORE_ROOT):
            raise PilotError(422, "profile_identity_mismatch")
        with self.transaction(create=True) as db:
            for ddl in (
                "CREATE TABLE config (id INTEGER PRIMARY KEY CHECK(id=1), profile BLOB NOT NULL,"
                " token_hash TEXT NOT NULL, expires INTEGER NOT NULL, enabled INTEGER NOT NULL,"
                " epoch INTEGER NOT NULL)",
                "CREATE TABLE admission (slot INTEGER PRIMARY KEY REFERENCES config(id),"
                " id TEXT NOT NULL UNIQUE, binding BLOB NOT NULL, artifact BLOB NOT NULL)",
                "CREATE TABLE job (slot INTEGER PRIMARY KEY REFERENCES admission(slot),"
                " id TEXT NOT NULL UNIQUE, terminal BLOB, evidence BLOB,"
                " CHECK((terminal IS NULL) = (evidence IS NULL)))",
                "CREATE TABLE replay (key TEXT PRIMARY KEY, digest TEXT NOT NULL, payload BLOB NOT NULL)",
            ):
                db.execute(ddl)
            db.execute("INSERT INTO config VALUES (1, ?, ?, ?, 1, 1)",
                       (canonical(profile), token_digest(token), expires))

    @staticmethod
    def config(db):
        return db.execute("SELECT * FROM config WHERE id=1").fetchone()

    @staticmethod
    def active(config, now):
        return config["enabled"] == 1 and now < config["expires"]

    def revoke(self):
        with self.transaction() as db:
            db.execute("UPDATE config SET enabled=0, epoch=epoch+1 WHERE enabled=1")

    def call(self, token, tool=None, args=None):
        with self.transaction(read_only=tool in (None, "library_discover", "receipt_get")) as db:
            config = self.config(db)
            now = int(time.time())
            if not (self.active(config, now)
                    and hmac.compare_digest(token_digest(token), config["token_hash"])):
                raise PilotError(401, "unauthorized")
            if tool is None:
                return {}
            profile = json.loads(config["profile"])
            lib = library(profile)
            if tool == "library_discover":
                exact_fields(args, ())
                return {"libraries": [lib], "core": CORE, "benefits": {"issuance_enabled": False}}
            if tool == "receipt_get":
                exact_fields(args, ("id",))
                return self.get_receipt(db, args["id"])
            if tool not in ("proof_submit", "verification_request"):
                raise PilotError(400, "unknown_tool")
            exact_fields(args, SUBMIT_FIELDS if tool == "proof_submit"
                         else ("idempotency_key", "submission_id"))
            key = args["idempotency_key"]
            if type(key) is not str or not 1 <= len(key.encode("utf-8")) <= 128:
                raise PilotError(400, "invalid_idempotency_key")
            request = commitment("request/v1", [tool, args])
            replay = db.execute("SELECT * FROM replay WHERE key=?", (key,)).fetchone()
            if replay is not None:
                if request != replay["digest"]:
                    raise PilotError(409, "idempotency_conflict")
                return json.loads(replay["payload"])
            if tool == "proof_submit":
                payload = self.admit(db, config, lib, profile, args, now)
            else:
                payload = self.enqueue(db, args["submission_id"])
            db.execute("INSERT INTO replay VALUES (?, ?, ?)", (key, request, canonical(payload)))
            return payload

    def admit(self, db, config, lib, profile, args, now):
        if (type(args["generation"]) is not int or args["generation"] != lib["generation"]
                or args["library"] != lib["id"] or args["revision"] != lib["revision"]
                or args["snapshot_sha256"] != lib["snapshot_sha256"]
                or args["target"] != lib["target"]):
            raise PilotError(422, "invalid_or_stale_binding")
        if type(args["artifact"]) is not str:
            raise PilotError(400, "invalid_artifact")
        artifact = args["artifact"].encode("utf-8")
        artifact_hash = digest(artifact)
        if not 0 < len(artifact) <= MAX_ARTIFACT or args["artifact_sha256"] != artifact_hash:
            raise PilotError(422, "invalid_artifact")
        if db.execute("SELECT 1 FROM admission").fetchone():
            raise PilotError(409, "capacity")

        # The fixture grant provides the only lease. The independent core
        # reference implements the same lease and submit steps as Lean.
        expected = Binding(**profile_binding(profile))
        core_cfg = RewardConfig(expected, reward=0, workerA=1, workerB=2)
        initial = reward_step(core_cfg, initial_reward(core_cfg), Tick(now))
        leased = reward_step(core_cfg, initial, Lease(1, config["expires"]))
        submitted = reward_step(
            core_cfg, leased, Submit(1, args["generation"], expected, int(artifact_hash, 16))
        )
        candidate = submitted.candidate
        if candidate is None:
            raise PilotError(422, "core_refused")
        binding = {
            **lib, "core": CORE, "worker": candidate.worker, "authority_epoch": config["epoch"],
            "artifact_sha256": artifact_hash, "submitted_at": candidate.submittedAt,
            "lease_expires": candidate.leaseExpires,
        }
        identity = commitment("admission/v1", binding)
        db.execute("INSERT INTO admission VALUES (1, ?, ?, ?)",
                   (identity, canonical(binding), artifact))
        return receipt("submitted", identity, binding)

    @staticmethod
    def admission(db, identity):
        if type(identity) is not str:
            raise PilotError(400, "invalid_id")
        row = db.execute("SELECT * FROM admission WHERE id=?", (identity,)).fetchone()
        if row is None:
            raise PilotError(404, "not_found")
        return row

    def enqueue(self, db, identity):
        row = self.admission(db, identity)
        if db.execute("SELECT 1 FROM job").fetchone():
            raise PilotError(409, "already_requested")
        binding = {**json.loads(row["binding"]), "submission_id": identity}
        job = commitment("job/v1", binding)
        db.execute("INSERT INTO job VALUES (1, ?, NULL, NULL)", (job,))
        return receipt("queued", job, binding)

    def get_receipt(self, db, identity):
        if type(identity) is not str:
            raise PilotError(400, "invalid_id")
        job = db.execute("SELECT * FROM job WHERE id=?", (identity,)).fetchone()
        if job is None:
            row = self.admission(db, identity)
            return receipt("submitted", identity, json.loads(row["binding"]))
        if job["terminal"] is not None:
            return json.loads(job["terminal"])
        row = db.execute("SELECT * FROM admission WHERE slot=1").fetchone()
        return receipt("queued", identity, {**json.loads(row["binding"]), "submission_id": row["id"]})

    def replay(self, checker, *, before_commit=lambda: None, after_commit=lambda: None):
        with self.transaction(read_only=True) as db:
            config = self.config(db)
            row = db.execute("SELECT * FROM admission WHERE slot=1").fetchone()
            job = db.execute("SELECT * FROM job WHERE slot=1").fetchone()
            if job is None:
                raise PilotError(404, "not_queued")
            binding = json.loads(row["binding"])
            if not self.active(config, int(time.time())) or config["epoch"] != binding["authority_epoch"]:
                raise PilotError(403, "stale_authority")
            profile = json.loads(config["profile"])
            if (any(binding.get(k) != v for k, v in library(profile).items())
                    or binding["core"] != CORE
                    or row["id"] != commitment("admission/v1", binding)
                    or job["id"] != commitment("job/v1", {**binding, "submission_id": row["id"]})
                    or digest(row["artifact"]) != binding["artifact_sha256"]):
                raise PilotError(503, "stored_identity_mismatch")
            if job["terminal"] is not None:
                return json.loads(job["terminal"])
        try:
            result = checker.check(profile, row["artifact"])
        except OSError as exc:
            raise PilotError(503, "checker_unavailable") from exc
        if (result.profile_sha256 != binding["profile_sha256"]
                or result.artifact_sha256 != binding["artifact_sha256"]):
            raise PilotError(503, "checker_binding_mismatch")
        if isinstance(result, RejectedExport):
            status = "profile_rejected"
            evidence = {"status": status, "reason": "exact_export_mismatch",
                        "artifact_sha256": result.artifact_sha256,
                        "profile_sha256": result.profile_sha256}
        else:
            status = "dual_checker_passed"
            evidence = result.receipt
        payload = receipt(status, job["id"], {**binding, "submission_id": row["id"]},
                          {"evidence_sha256": digest(canonical(evidence))})
        with self.transaction() as db:
            current = self.config(db)
            current_row = db.execute("SELECT * FROM admission WHERE slot=1").fetchone()
            current_job = db.execute("SELECT * FROM job WHERE slot=1").fetchone()
            if current != config or not self.active(current, int(time.time())):
                raise PilotError(403, "stale_authority")
            if current_row != row or current_job is None or current_job["id"] != job["id"]:
                raise PilotError(409, "stale_candidate")
            if current_job["terminal"] is not None:
                return json.loads(current_job["terminal"])
            db.execute("UPDATE job SET terminal=?, evidence=? WHERE slot=1",
                       (canonical(payload), canonical(evidence)))
            before_commit()
        after_commit()
        return payload


def port(store):
    stream = sys.stdin.buffer
    while header := stream.read(4):
        if len(header) != 4:
            raise EOFError("incomplete port frame")
        size, = struct.unpack(">I", header)
        if not 0 < size <= MAX_PACKET:
            raise ValueError("invalid port frame")
        raw = stream.read(size)
        if len(raw) != size:
            raise EOFError("incomplete port frame")
        try:
            request = parse_json(raw)
            if "tool" in request and type(request["tool"]) is not str:
                raise PilotError(400, "unknown_tool")
            response = {"ok": store.call(request["token"], request.get("tool"), request.get("args"))}
        except PilotError as exc:
            response = {"error": exc.code}
        except sqlite3.Error:
            response = {"error": "storage_unavailable"}
        data = canonical(response)
        sys.stdout.buffer.write(struct.pack(">I", len(data)) + data)
        sys.stdout.buffer.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("port")
    provision = commands.add_parser("provision")
    provision.add_argument("--profile", type=Path, required=True)
    commands.add_parser("revoke")
    worker = commands.add_parser("replay")
    worker.add_argument("--lean-root", type=Path, required=True)
    worker.add_argument("--application-path-adapter", type=Path)
    args = parser.parse_args()
    store = Store(args.db)
    try:
        if args.command == "port":
            port(store)
        elif args.command == "provision":
            store.provision(parse_json(args.profile.read_bytes()),
                            os.environ["RESEARCH_EXCHANGE_TOKEN"], int(time.time()) + 3600)
        elif args.command == "revoke":
            store.revoke()
        else:
            checker = ControlledChecker(args.lean_root, CORE_ROOT, args.application_path_adapter)
            print(canonical(store.replay(checker)).decode("ascii"))
    except PilotError as exc:
        print(exc.code, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
