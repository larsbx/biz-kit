"""Exercise real loopback HTTP, pinned proof checkers and file-backed SQLite.

These tests are deliberately separate from the service implementation. Most
observations cross HTTP or use an independent SQL connection. Trusted offline
administration and checker fault injection are labeled explicitly.
Credentials and database files are temporary; persisted transcripts omit them.
"""
from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from adapter_pilot.checker import CheckedExport, ControlledChecker, RejectedExport
from adapter_pilot.common import MAX_BODY, MAX_INTEGER, PilotError, canonical, digest
from adapter_pilot.server import Service, make_server
from adapter_pilot.prepare_fixture import prepare_fixture
from adapter_pilot.store import PreparedVerification, Store


PACKAGE = Path(__file__).resolve().parents[2]


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class AcceptanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Missing tool configuration is a hard error, never a skipped test.
        cls.lean_root = Path(os.environ["FRE_LEAN_ROOT"]).resolve(strict=True)
        shim = os.environ.get("FRE_APP_PATH_SHIM")
        cls.shim = Path(shim).resolve(strict=True) if shim else None
        cls.output = Path(os.environ["FRE_ADAPTER_TEST_OUTPUT"]).resolve()
        cls.output.mkdir(parents=True, exist_ok=True)
        fixture = prepare_fixture(PACKAGE, cls.lean_root, cls.output / "fixtures", cls.shim)
        cls.profile = fixture["profile"]
        cls.expected = Path(fixture["expected_path"]).read_bytes()
        cls.alternate = Path(fixture["alternate_path"]).read_bytes()
        cls.checker = ControlledChecker(cls.lean_root, PACKAGE, cls.shim)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="exchange-acceptance-")
        self.addCleanup(self.directory.cleanup)
        self.temp = Path(self.directory.name)
        self.evidence = self.output / self._testMethodName
        self.evidence.mkdir()
        self.db = self.temp / "pilot.sqlite"
        self.store = Store(self.db)
        self.store.initialize()
        for slot in ("main", "other"):
            self.store.provision_slot(slot, self.profile, reward=5)
        self.tokens = {name: secrets.token_urlsafe(32) for name in (
            "worker_a", "worker_b", "verifier", "wrong_verifier", "other_scope")}
        self.store.provision_credential(self.tokens["worker_a"], 10, "worker", ["main", "other"])
        self.store.provision_credential(self.tokens["worker_b"], 20, "worker", ["main"])
        self.store.provision_credential(self.tokens["verifier"], 30, "verifier", ["main", "other"])
        self.store.provision_credential(self.tokens["wrong_verifier"], 31, "verifier", ["main"])
        self.store.provision_credential(self.tokens["other_scope"], 10, "worker", ["other"])
        self.servers = []
        self.transcript = []
        self.transcript_lock = threading.Lock()
        self.addCleanup(self.finish)
        self.server = self.start_server()

    def finish(self):
        processes = []
        for process, port, log in self.servers:
            observed_exit = process.poll()
            if observed_exit is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            processes.append({"pid": process.pid, "port": port,
                              "exit_before_cleanup": observed_exit,
                              "exit_after_cleanup": process.returncode})
            log.close()
        write_json(self.evidence / "http-transcript.json", self.transcript)
        write_json(self.evidence / "processes.json", processes)
        if self.db.exists():
            write_json(self.evidence / "database-observation.json", self.snapshot())

    def start_server(self, **hooks):
        number = len(self.servers)
        ready = self.temp / f"ready-{number}.json"
        command = [sys.executable, "-m", "adapter_pilot.server", "--db", str(self.db),
                   "--lean-root", str(self.lean_root), "--package-root", str(PACKAGE),
                   "--ready-file", str(ready), "--port", "0"]
        if self.shim:
            command += ["--application-path-adapter", str(self.shim)]
        for key, value in hooks.items():
            command += ["--" + key.replace("_", "-"), str(value)]
        log = (self.evidence / f"server-{number}.log").open("wb")
        process = subprocess.Popen(command, cwd=PACKAGE, stdout=log, stderr=subprocess.STDOUT)
        self.servers.append((process, None, log))
        deadline = time.monotonic() + 30
        while not ready.is_file():
            if process.poll() is not None:
                self.fail(f"server exited {process.returncode}; see server-{number}.log")
            if time.monotonic() >= deadline:
                self.fail("server did not announce readiness")
            time.sleep(0.01)
        info = json.loads(ready.read_text())
        self.assertEqual(info["host"], "127.0.0.1")
        self.assertEqual(info["scope"], "local-fixture-credits-only")
        self.servers[-1] = (process, info["port"], log)
        return self.servers[-1]

    def request(self, path, body=None, *, identity="worker_a", method="POST",
                server=None, raw=None, headers=None, allow_disconnect=False):
        _process, port, _log = server or self.server
        payload = raw if raw is not None else (
            json.dumps(body, sort_keys=True, separators=(",", ":")).encode() if body is not None else None)
        request_headers = {"Content-Type": "application/json"}
        if identity is not None:
            token = self.tokens.get(identity, identity)
            request_headers["Authorization"] = "Bearer " + token
        if headers:
            request_headers.update(headers)
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        try:
            connection.request(method, path, payload, request_headers)
            response = connection.getresponse()
            status, result = response.status, json.loads(response.read())
        except (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError):
            if not allow_disconnect:
                raise
            status, result = None, {"transport": "connection_closed_before_response"}
        finally:
            connection.close()
        # Record canonical body identity, never bearer tokens or artifact bytes.
        event = {"method": method, "path": path, "authenticated_as": identity if identity in self.tokens else
                 ("missing" if identity is None else "unrecognized"), "status": status, "response": result,
                 "request_body_sha256": hashlib.sha256(payload or b"").hexdigest(),
                 "request_body_bytes": len(payload or b"")}
        with self.transcript_lock:
            self.transcript.append(event)
        return status, result

    def snapshot(self):
        # Independent reads: do not rely on the service's inspect/view helpers.
        with sqlite3.connect(self.db, isolation_level=None) as connection:
            connection.row_factory = sqlite3.Row
            slots = [dict(row) for row in connection.execute(
                "SELECT slot_id,version,state_json,candidate_sha256,artifact_sha256 FROM slots ORDER BY slot_id")]
            for row in slots:
                row["state"] = json.loads(row.pop("state_json"))
            settlements = [dict(row) for row in connection.execute("SELECT * FROM settlements ORDER BY slot_id")]
            refunds = [dict(row) for row in connection.execute("SELECT * FROM refunds ORDER BY slot_id")]
            requests = [dict(row) for row in connection.execute(
                "SELECT principal,request_id,request_sha256,operation,slot_id,status_code,response_json "
                "FROM requests ORDER BY principal,request_id")]
            return {"slots": slots, "settlements": settlements, "refunds": refunds, "requests": requests,
                    "sqlite_version": sqlite3.sqlite_version,
                    "journal_mode": connection.execute("PRAGMA journal_mode").fetchone()[0],
                    "integrity_check": connection.execute("PRAGMA integrity_check").fetchone()[0]}

    def assert_financial(self, payouts, *, worker=10, refunds=0):
        observed = self.snapshot()
        row = next(x for x in observed["slots"] if x["slot_id"] == "main")
        state = row["state"]
        self.assertEqual(state["payouts"], payouts)
        self.assertEqual(len(observed["settlements"]), payouts)
        self.assertEqual(len(observed["refunds"]), refunds)
        self.assertEqual(state["funder"], 7 + 5 * refunds)
        self.assertEqual(sum(state[k] for k in ("funder", "escrow", "balanceA", "balanceB")), 12)
        self.assertEqual(state["escrow"], 5 * (1 - payouts - refunds))
        self.assertEqual(state["balanceA"], 5 if payouts and worker == 10 else 0)
        self.assertEqual(state["balanceB"], 5 if payouts and worker == 20 else 0)
        self.assertEqual(observed["integrity_check"], "ok")
        self.assertEqual(observed["journal_mode"].lower(), "wal")
        if payouts:
            ledger = observed["settlements"][0]
            self.assertEqual(ledger["worker"], worker)
            self.assertEqual(ledger["amount"], 5)
            self.assertEqual(ledger["version"], row["version"])
            self.assertEqual(state["phase"], "accepted")
        if refunds:
            ledger = observed["refunds"][0]
            self.assertEqual(ledger["amount"], 5)
            self.assertEqual(ledger["version"], row["version"])
            self.assertEqual(ledger["candidate_sha256"], row["candidate_sha256"])
            self.assertEqual(state["phase"], "rejected")
        return observed

    def assert_domain_unchanged(self, before):
        after = self.snapshot()
        # Valid domain refusals may add a request audit row. They may not alter
        # reward/candidate identity, version, or any settlement record.
        for key in ("slots", "settlements", "refunds"):
            self.assertEqual(after[key], before[key], key + " mutated on refusal")

    def lease(self, *, request_id="lease", ttl=30000, identity="worker_a"):
        return self.request("/v1/slots/main/lease", {"request_id": request_id, "ttl_ms": ttl}, identity=identity)

    def submit(self, generation, *, artifact=None, request_id="submit", identity="worker_a"):
        return self.request("/v1/slots/main/submit", {
            "request_id": request_id, "generation": generation,
            "artifact_base64": base64.b64encode(self.expected if artifact is None else artifact).decode(),
        }, identity=identity)

    def admit(self, *, artifact=None, ttl=30000):
        status, lease = self.lease(ttl=ttl)
        self.assertEqual(status, 200)
        status, submitted = self.submit(lease["state"]["generation"], artifact=artifact)
        self.assertEqual(status, 200)
        self.assertEqual(submitted["state"]["phase"], "submitted")
        return submitted

    def verify(self, request_id="verify", **options):
        return self.request("/internal/slots/main/verify", {"request_id": request_id},
                            identity="verifier", **options)

    def wait_past(self, milliseconds):
        while time.time_ns() // 1_000_000 <= milliseconds:
            time.sleep(0.01)

    def test_authenticated_workers_contend_for_one_lease(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(self.lease, request_id="race-" + name, identity=name)
                    for name in ("worker_a", "worker_b")]
            results = [job.result() for job in jobs]
        self.assertEqual(sorted(status for status, _ in results), [200, 409])
        winner = next(body for status, body in results if status == 200)
        owner = winner["state"]["owner"]
        losing_identity = "worker_b" if owner == 10 else "worker_a"
        self.assertEqual(self.submit(winner["state"]["generation"], identity=losing_identity)[0], 409)
        winning_identity = "worker_a" if owner == 10 else "worker_b"
        self.assertEqual(self.submit(winner["state"]["generation"], identity=winning_identity)[0], 200)
        self.assertEqual(self.verify()[0], 200)
        self.assert_financial(1, worker=owner)

    def test_credentials_roles_scopes_and_revocation(self):
        before = self.snapshot()
        for identity, status in ((None, 401), (secrets.token_urlsafe(32), 401),
                                 ("other_scope", 403), ("verifier", 403), ("wrong_verifier", 403)):
            with self.subTest(identity="missing" if identity is None else "credential"):
                self.assertEqual(self.lease(identity=identity)[0], status)
        self.assertEqual(self.request("/internal/slots/main/verify", {"request_id": "wrong"},
                                      identity="wrong_verifier")[0], 403)
        self.store.revoke_credential(self.tokens["worker_a"])
        self.assertEqual(self.lease()[0], 403)
        self.assert_domain_unchanged(before)
        self.assert_financial(0)

    def test_worker_cannot_supply_acceptance_authority(self):
        self.admit()
        before = self.snapshot()
        self.assertEqual(self.request("/internal/slots/main/verify", {"request_id": "worker-verify"})[0], 403)
        self.assertEqual(self.request("/v1/slots/main/accept", {"trusted": True})[0], 404)
        for field, value in (("trusted", True), ("verdict", "passed"), ("receipt", {}),
                             ("profile", self.profile), ("worker", 10), ("checker_command", "true")):
            with self.subTest(field=field):
                self.assertEqual(self.request("/internal/slots/main/verify",
                                              {"request_id": "forged", field: value}, identity="verifier")[0], 400)
        self.assert_domain_unchanged(before)
        self.assert_financial(0)

    def test_strict_schema_and_numeric_bounds(self):
        before = self.snapshot()
        for ttl in (True, False, -1, 0, 1.5, "100", MAX_INTEGER + 1):
            with self.subTest(ttl=ttl):
                self.assertEqual(self.lease(ttl=ttl)[0], 400)
        self.assertEqual(self.request("/v1/slots/main/lease", raw=
            b'{"request_id":"dup","ttl_ms":1000,"ttl_ms":2000}')[0], 400)
        self.assertEqual(self.request("/v1/slots/main/lease",
                                     {"request_id": "spoof", "ttl_ms": 1000, "worker": 20})[0], 400)
        self.assertEqual(self.request("/v1/slots/main/lease", raw=b"[1,2]")[0], 400)
        for generation in (True, -1, 0, 1.5, MAX_INTEGER + 1):
            self.assertEqual(self.submit(generation)[0], 400)
        for encoded in ("!!!", "", "Zg===", "Zg==\n", "Zh=="):
            self.assertEqual(self.request("/v1/slots/main/submit", {
                "request_id": "bad-artifact", "generation": 1, "artifact_base64": encoded})[0], 400)
        self.assert_domain_unchanged(before)
        self.assert_financial(0)

    def test_http_framing_and_body_limits(self):
        before = self.snapshot()
        port = self.server[1]
        cases = [(["Content-Length: 2", "Content-Length: 2"], 400),
                 (["Transfer-Encoding: chunked", "Content-Length: 2"], 400),
                 ([f"Content-Length: {MAX_BODY + 1}"], 413),
                 (["Content-Length: 2", "Content-Type: text/plain"], 415)]
        for extra, expected in cases:
            with self.subTest(headers=extra):
                headers = ["POST /v1/slots/main/lease HTTP/1.0", "Host: 127.0.0.1",
                           "Authorization: Bearer " + self.tokens["worker_a"],
                           "Content-Type: application/json", *extra, "", "{}"]
                with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                    connection.sendall("\r\n".join(headers).encode())
                    response = http.client.HTTPResponse(connection)
                    response.begin()
                    self.assertEqual(response.status, expected)
                    result = json.loads(response.read())
                    self.transcript.append({"framing_case": extra, "status": response.status, "response": result})
        self.assert_domain_unchanged(before)
        self.assert_financial(0)

    def test_request_id_is_permanently_bound_to_content_operation_and_slot(self):
        first = self.lease(request_id="permanent")
        self.assertEqual(first[0], 200)
        before = self.snapshot()
        self.assertEqual(self.lease(request_id="permanent"), first)
        self.assertEqual(self.lease(request_id="permanent", ttl=25000), (409, {"error": "request_conflict"}))
        self.assertEqual(self.submit(first[1]["state"]["generation"], request_id="permanent")[0], 409)
        self.assertEqual(self.request("/v1/slots/other/lease", {"request_id": "permanent", "ttl_ms": 30000})[0], 409)
        self.assert_domain_unchanged(before)
        self.assert_financial(0)

    def test_expired_and_same_worker_stale_generation_refused(self):
        status, old = self.lease(ttl=120)
        self.assertEqual(status, 200)
        self.wait_past(old["state"]["expires"])
        self.assertEqual(self.submit(old["state"]["generation"], request_id="late")[0], 409)
        status, new = self.lease(request_id="reassigned")
        self.assertEqual(status, 200)
        self.assertEqual(new["state"]["generation"], old["state"]["generation"] + 1)
        self.assertEqual(self.submit(old["state"]["generation"], request_id="stale")[0], 409)
        self.assertEqual(self.submit(new["state"]["generation"], request_id="fresh")[0], 200)
        self.assert_financial(0)

    def test_admitted_candidate_can_be_verified_after_lease_expiry(self):
        admitted = self.admit(ttl=500)
        self.wait_past(admitted["state"]["expires"])
        status, result = self.verify()
        self.assertEqual(status, 200)
        self.assertEqual(result["state"]["candidate"], admitted["state"]["candidate"])
        checkers = result["settlement"]["verification"]["checkers"]
        self.assertEqual([r["checker"] for r in checkers], ["leanchecker", "lean4lean"])
        self.assertTrue(all(r["exit_code"] == 0 for r in checkers))
        self.assert_financial(1)

    def test_valid_proof_for_other_target_refunds_and_preserves_history(self):
        # Preparation has already independently checked this alternate proof.
        self.assertNotEqual(hashlib.sha256(self.alternate).digest(), hashlib.sha256(self.expected).digest())
        admitted = self.admit(artifact=self.alternate)
        before = self.snapshot()
        status, closed = self.verify()
        self.assertEqual(status, 422)
        self.assertEqual(closed["error"], "proof_refused")
        self.assertEqual(closed["refund"]["reason"], "exact_export_mismatch")
        self.assertEqual(closed["refund"]["destination"], "original_slot_funder")
        self.assertEqual(closed["state"]["candidate"], admitted["state"]["candidate"])
        self.assertEqual(closed["version"], admitted["version"] + 1)
        after = self.assert_financial(0, refunds=1)
        self.assertTrue(all(record in after["requests"] for record in before["requests"]))
        self.assertEqual(self.verify(), (status, closed))
        self.assertEqual(self.verify("another-rejection"), (status, closed))
        self.assertEqual(self.lease(request_id="cannot-reassign")[0], 409)
        self.assertEqual(self.submit(admitted["state"]["generation"], request_id="cannot-resubmit")[0], 409)
        self.assertEqual(self.submit(admitted["state"]["generation"], artifact=self.alternate), (200, admitted))
        self.assertEqual(self.request("/v1/slots/main/reissue", {"request_id": "reissue"})[0], 404)
        self.assertEqual(self.request("/internal/slots/other/verify", {"request_id": "verify"},
                                      identity="verifier"), (409, {"error": "request_conflict"}))
        self.assert_domain_unchanged(after)
        with self.assertRaises(TypeError):
            self.store.provision_slot("replacement", self.profile)
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.provision_slot("main", self.profile, reward=5)
        self.store.provision_slot("replacement", self.profile, reward=3)
        replacement = self.store.inspect("replacement")
        self.assertEqual(replacement["state"]["escrow"], 3)
        self.assertEqual(replacement["state"]["phase"], "open")
        self.assertIsNone(replacement["state"]["candidate"])
        self.assertEqual(replacement["requests"], [])
        self.assertEqual(self.verify(), (status, closed))

    def test_pr335_immutable_profile_survives_upgrade(self):
        files = dict(self.profile["source_files"])
        # Only these proof-source entries changed from PR #335.
        del files["formal/lean/ResearchExchange/Closure.lean"]
        files["formal/lean/ResearchExchange.lean"] = "57081adb691f5ebc1ef31456e9a255e6e6caa2989350f56b409205ecc9365446"
        files["formal/lean/ResearchExchange/Reward.lean"] = "9bce1f0f0993b0c49b60e80f7df0e58fa2ab44c29172295eec4014ad1d5eea9a"
        previous = {**self.profile, "source_files": files, "source_sha256": digest(canonical(files))}
        self.assertIsInstance(self.checker.check(previous, self.expected), CheckedExport)
        self.assertIsInstance(self.checker.check(previous, self.alternate), RejectedExport)
        files["formal/lean/ResearchExchange.lean"] = "0" * 64
        previous["source_sha256"] = digest(canonical(files))
        with self.assertRaisesRegex(PilotError, "profile_identity_mismatch"):
            self.checker.check(previous, self.alternate)

    def test_unapproved_bytes_never_acquire_checker_authority(self):
        # Calibrate a harmless executable source fixture in the trusted harness.
        # If a future runtime compiles this contributor payload before refusing
        # it, the sentinel detects that execution even if no payout follows.
        sentinel = self.temp / "source-executed"
        payload = ('import Lean\n#eval IO.FS.writeFile ' + json.dumps(str(sentinel)) +
                   ' "UNTRUSTED_SOURCE_EXECUTED"\n').encode()
        calibration = self.temp / "Calibration.lean"
        calibration.write_bytes(payload)
        calibrated = subprocess.run([str(self.checker.paths["lean"]), str(calibration)],
                                    env=self.checker.environment(), cwd=self.temp,
                                    capture_output=True, timeout=30, check=False)
        self.assertEqual(calibrated.returncode, 0, calibrated.stderr.decode(errors="replace"))
        self.assertEqual(sentinel.read_text(), "UNTRUSTED_SOURCE_EXECUTED")
        sentinel.unlink()
        self.assertFalse(sentinel.exists())
        self.admit(artifact=payload)
        status, closed = self.verify()
        self.assertEqual(status, 422)
        self.assertEqual(closed["refund"]["reason"], "exact_export_mismatch")
        self.assertFalse(sentinel.exists(), "contributor source executed before refusal")
        write_json(self.evidence / "source-execution-control.json", {
            "trusted_calibration_exit": calibrated.returncode, "trusted_calibration_wrote_sentinel": True,
            "http_submission_executed_source": sentinel.exists()})
        self.assert_financial(0, refunds=1)

    def concurrent_closures(self, *, rejecting=False):
        admitted = self.admit(artifact=self.alternate if rejecting else self.expected)
        pauses = [self.temp / "concurrent-a", self.temp / "concurrent-b"]
        servers = [self.start_server(pause_after_verification=pause, pause_request_id=pause.name)
                   for pause in pauses]
        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(self.verify, pause.name, server=server)
                    for pause, server in zip(pauses, servers)]
            try:
                deadline = time.monotonic() + 20
                ready_paths = [Path(str(pause) + ".ready") for pause in pauses]
                while not all(path.is_file() for path in ready_paths):
                    self.assertFalse(any(job.done() for job in jobs), "verification escaped the prepared barrier")
                    if time.monotonic() >= deadline:
                        self.fail("both verification decisions did not reach the commit barrier")
                    time.sleep(0.01)
                preparations = [json.loads(path.read_text()) for path in ready_paths]
                self.assertEqual([p["version"] for p in preparations], [admitted["version"]] * 2)
                self.assertEqual(len({p["pid"] for p in preparations}), 2)
                self.assert_financial(0)
                write_json(self.evidence / "concurrent-precommit-barrier.json", preparations)
            finally:
                for pause in pauses:
                    Path(str(pause) + ".release").write_text("release\n")
            results = [job.result() for job in jobs]
        self.assertEqual([status for status, _ in results], [422 if rejecting else 200] * 2)
        self.assertEqual(results[0][1], results[1][1])
        self.assertEqual(self.verify("concurrent-a", server=servers[1]), results[0])
        self.assertEqual(self.verify("new-retry"), results[0])
        observed = self.assert_financial(int(not rejecting), refunds=int(rejecting))
        self.assertEqual({r["request_id"] for r in observed["requests"] if r["operation"] == "verify"},
                         {"concurrent-a", "concurrent-b", "new-retry"})
        self.store.revoke_credential(self.tokens["verifier"])
        self.assertEqual(self.verify("concurrent-a")[0], 403)
        self.assert_financial(int(not rejecting), refunds=int(rejecting))

    def test_concurrent_processes_settle_once_and_replay_receipt(self):
        self.concurrent_closures()

    def test_concurrent_processes_refund_once_and_replay_receipt(self):
        self.concurrent_closures(rejecting=True)

    def paused_verification(self, mutation, expected_status, *, artifact=None):
        self.admit(artifact=artifact)
        pause = self.temp / "pause"
        server = self.start_server(pause_after_verification=pause, pause_request_id="paused")
        with ThreadPoolExecutor(max_workers=1) as pool:
            job = pool.submit(self.verify, "paused", server=server)
            deadline = time.monotonic() + 30
            while not Path(str(pause) + ".ready").exists():
                if job.done():
                    self.fail(f"verification finished before its pause: {job.result()}")
                if time.monotonic() >= deadline:
                    self.fail("controlled verification never reached the commit boundary")
                time.sleep(0.01)
            try:
                mutation()
            finally:
                Path(str(pause) + ".release").write_text("release\n")
            self.assertEqual(job.result()[0], expected_status)
        self.assert_financial(0)

    def test_revocation_during_actual_check_prevents_commit(self):
        self.paused_verification(lambda: self.store.revoke_credential(self.tokens["verifier"]), 403)

    def test_revoke_regrant_epoch_prevents_aba_commit(self):
        def mutate():
            self.store.revoke_credential(self.tokens["verifier"])
            self.store.set_credential_enabled(self.tokens["verifier"], True)
        self.paused_verification(mutate, 409)

    def test_row_version_interference_prevents_commit(self):
        def mutate():
            # Trusted fault injection; no HTTP operation can write a version.
            with sqlite3.connect(self.db) as connection:
                connection.execute("UPDATE slots SET version=version+1 WHERE slot_id='main'")
        self.paused_verification(mutate, 409)

    def test_artifact_replacement_after_check_prevents_commit(self):
        def mutate():
            # Trusted storage fault, not a claim to withstand a hostile host.
            with sqlite3.connect(self.db) as connection:
                connection.execute("UPDATE slots SET artifact=? WHERE slot_id='main'", (self.alternate,))
        self.paused_verification(mutate, 409)

    def crash_case(self, point, expected_exit, *, rejecting=False):
        self.admit(artifact=self.alternate if rejecting else self.expected)
        server = self.start_server(failpoint=point, failpoint_request_id="crashing")
        self.assertIsNone(self.verify("crashing", server=server, allow_disconnect=True)[0])
        self.assertEqual(server[0].wait(timeout=10), expected_exit)
        committed = int(point == "after_commit")
        observed = self.assert_financial(0 if rejecting else committed,
                                         refunds=committed if rejecting else 0)
        write_json(self.evidence / "after-crash-before-retry.json", observed)
        bound = [r for r in observed["requests"] if r["request_id"] == "crashing"]
        self.assertEqual(len(bound), committed)
        restarted = self.start_server()
        first = self.verify("crashing", server=restarted)
        self.assertEqual(first[0], 422 if rejecting else 200)
        if bound:
            self.assertEqual(first[1], json.loads(bound[0]["response_json"]))
        self.assertEqual(self.verify("crashing", server=restarted), first)
        self.assertEqual(self.verify("retry-new-id", server=restarted), first)
        self.assert_financial(int(not rejecting), refunds=int(rejecting))

    def test_process_crash_before_commit_rolls_back_all_effects(self):
        self.crash_case("before_commit", 86)

    def test_process_crash_after_commit_retains_outcome_and_retry(self):
        self.crash_case("after_commit", 87)

    def test_process_crash_before_rejection_rolls_back_refund_and_receipt(self):
        self.crash_case("before_commit", 86, rejecting=True)

    def test_process_crash_after_rejection_retains_refund_and_receipt(self):
        self.crash_case("after_commit", 87, rejecting=True)

    def test_revocation_fences_prepared_rejection(self):
        self.paused_verification(lambda: self.store.revoke_credential(self.tokens["verifier"]),
                                 403, artifact=self.alternate)

    def test_version_change_fences_prepared_rejection(self):
        def interfere():
            with sqlite3.connect(self.db) as connection:
                connection.execute("UPDATE slots SET version=version+1 WHERE slot_id='main'")
        self.paused_verification(interfere, 409, artifact=self.alternate)

    def test_checker_unavailability_and_inconclusive_exit_do_not_refund(self):
        self.admit()
        before = self.snapshot()
        server = make_server(Service(self.store, self.checker))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()

        def close():
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)

        self.addCleanup(close)
        local = (None, server.server_address[1], None)
        faults = (
            ("timeout", subprocess.TimeoutExpired("leanchecker", 1), "checker_unavailable"),
            ("missing", FileNotFoundError(), "checker_unavailable"),
            ("nonzero", subprocess.CompletedProcess([], 1, b"", b"error"), "checker_inconclusive"),
            ("missing-marker", subprocess.CompletedProcess([], 0, b"", b""), "checker_inconclusive"),
        )
        for name, fault, error in faults:
            with self.subTest(name=name):
                options = {"side_effect": fault} if isinstance(fault, Exception) else {"return_value": fault}
                with patch("adapter_pilot.checker.subprocess.run", **options) as invoke:
                    self.assertEqual(self.verify(name, server=local), (503, {"error": error}))
                    invoke.assert_called_once()
                self.assert_domain_unchanged(before)
                self.assert_financial(0)
                self.assertEqual(self.verify(name), (503, {"error": error}))
        self.assertEqual(self.verify("new-check")[0], 200)
        self.assert_financial(1)

    def test_opposing_prepared_verdicts_cannot_overwrite_closure(self):
        self.admit(artifact=self.alternate)
        verifier = self.tokens["verifier"]
        stale = self.store.prepare_verification(verifier, "main", {"request_id": "stale-accept"})
        self.assertIsInstance(stale, PreparedVerification)
        # Fault injection at the trusted checker/store interface: honest
        # verification cannot produce both decisions for these immutable bytes.
        false_accept = CheckedExport(stale.profile_sha256, stale.artifact_sha256, {})
        with self.assertRaisesRegex(PilotError, "decision_evidence_mismatch"):
            self.store.commit_verification(stale, false_accept)
        pause = self.temp / "reject"
        server = self.start_server(pause_after_verification=pause, pause_request_id="reject")
        with ThreadPoolExecutor(max_workers=2) as pool:
            rejection = pool.submit(self.verify, "reject", server=server)
            ready = Path(str(pause) + ".ready")
            deadline = time.monotonic() + 20
            while not ready.exists():
                self.assertFalse(rejection.done())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            with self.store.transaction():
                # Hold the SQLite writer lock while both decisions contend.
                acceptance = pool.submit(self.store.commit_verification, stale, false_accept)
                Path(str(pause) + ".release").write_text("release")
            winner = rejection.result(timeout=10)
            try:
                losing_reply = acceptance.result(timeout=10)
            except PilotError as exc:
                self.assertEqual(exc.code, "decision_evidence_mismatch")
            else:
                self.assertEqual((losing_reply.status, losing_reply.body), winner)
        self.assertEqual(winner[0], 422)
        self.assertEqual(self.verify("stale-accept"), winner)
        self.assert_financial(0, refunds=1)

    def test_rejection_evidence_cannot_be_forged_for_approved_export(self):
        self.admit()
        prepared = self.store.prepare_verification(self.tokens["verifier"], "main",
                                                   {"request_id": "false-reject"})
        self.assertIsInstance(prepared, PreparedVerification)
        with self.assertRaisesRegex(PilotError, "decision_evidence_mismatch"):
            self.store.commit_verification(
                prepared, RejectedExport(prepared.profile_sha256, prepared.artifact_sha256))
        self.assert_financial(0)
        self.assertEqual(self.verify("real-accept")[0], 200)
        original = self.assert_financial(1)
        replay = self.store.commit_verification(
            prepared, RejectedExport(prepared.profile_sha256, prepared.artifact_sha256))
        self.assertEqual((replay.status, replay.body), self.verify("real-accept"))
        self.assert_domain_unchanged(original)

    def test_checker_failure_racing_settlement_still_binds_request_id(self):
        self.admit()
        # Direct trusted-store scheduling isolates an otherwise nondeterministic
        # checker-failure race. The winning check below is the real dual replay.
        a = self.store.prepare_verification(self.tokens["verifier"], "main", {"request_id": "failure-race"})
        b = self.store.prepare_verification(self.tokens["verifier"], "main", {"request_id": "winning-race"})
        self.assertIsInstance(a, PreparedVerification)
        self.assertIsInstance(b, PreparedVerification)
        checked = self.checker.check(b.profile, b.artifact)
        winner = self.store.commit_verification(b, checked)
        loser = self.store.record_verification_failure(a, PilotError(503, "checker_unavailable"))
        self.assertEqual(loser, winner)
        observed = self.assert_financial(1)
        self.assertIn("failure-race", {r["request_id"] for r in observed["requests"]})
        self.assertEqual(self.request("/internal/slots/other/verify", {"request_id": "failure-race"},
                                      identity="verifier"), (409, {"error": "request_conflict"}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
