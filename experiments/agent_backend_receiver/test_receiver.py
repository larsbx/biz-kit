"""Real process/SQLite acceptance for the inert reference receiver only.

No provider, model, OS execution worker, business authority or termination
claim is made by an accepted request identity.
"""

from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

import receiver


HERE = Path(__file__).resolve().parent
RECEIVER = HERE / "receiver.py"
BARRIER = HERE / "barrier_receiver.py"
RECEIPT_KEYS = {
    "schema", "operation", "store_id", "effect_id", "state", "backend_id",
    "admission_id", "plan_digest", "execution_deadline", "disposition",
    "execution_started", "termination_verified", "future_creates_refused",
}


class ReceiverTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agent-backend-test-")
        self.addCleanup(self.directory.cleanup)
        self.db = Path(self.directory.name) / "receiver.sqlite"
        response, status = self.invoke("init")
        self.assertEqual(status, 0, response)
        self.assertEqual(set(response), {"schema", "store_id"})
        self.assertEqual(response["schema"], receiver.STORE_SCHEMA)
        self.store_id = response["store_id"]
        self.assertRegex(self.store_id, r"\Aagent-backend-store:[0-9a-f]{32}\Z")
        self.deadline = (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat(
            timespec="microseconds").replace("+00:00", "Z")

    def invoke(self, operation, request=None, *, db=None, raw=None):
        args = [sys.executable, str(RECEIVER), operation, "--db", str(db or self.db)]
        data = raw if raw is not None else json.dumps(request).encode() if request is not None else b""
        process = subprocess.run(args, input=data, capture_output=True, timeout=8, check=False)
        self.assertEqual(process.stderr, b"", process.stderr.decode(errors="replace"))
        self.assertEqual(len(process.stdout.splitlines()), 1)
        return json.loads(process.stdout), process.returncode

    def request(self, operation="create", effect="agent-run:fixture-1", **changes):
        value = {"schema": receiver.REQUEST_SCHEMA, "operation": operation,
                 "store_id": self.store_id, "effect_id": effect}
        if operation == "create":
            value.update(admission_id="agent-admission:" + hashlib.sha256(effect.encode()).hexdigest(),
                         plan_digest="a" * 64, execution_deadline=self.deadline)
        value.update(changes)
        return value

    def send(self, request, *, db=None):
        return self.invoke("request", request, db=db)

    def accepted(self, request=None):
        response, status = self.send(request or self.request())
        self.assertEqual(status, 0, response)
        self.assert_receipt(response, "accepted")
        return response

    def assert_receipt(self, response, state):
        self.assertEqual(set(response), RECEIPT_KEYS)
        self.assertEqual(response["schema"], receiver.RECEIPT_SCHEMA)
        self.assertEqual(response["store_id"], self.store_id)
        self.assertEqual(response["state"], state)
        self.assertIs(response["execution_started"], False)
        self.assertIs(response["termination_verified"], False)
        self.assertIs(response["future_creates_refused"], state == "fenced")

    def assert_error(self, result, code, status=2, store_id=None):
        response, actual_status = result
        self.assertEqual(actual_status, status, response)
        self.assertEqual(response, {"schema": receiver.ERROR_SCHEMA, "error": code,
                                    "store_id": self.store_id if store_id is None else store_id})

    def spawn(self, request, *, barrier=False, mode=None):
        args = [sys.executable, str(BARRIER), str(self.db)] if barrier else [
            sys.executable, str(RECEIVER), "request", "--db", str(self.db)]
        if mode is not None:
            args.append(mode)
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        self.addCleanup(self.stop, process)
        process.stdin.write(json.dumps(request).encode())
        process.stdin.close()
        process.stdin = None
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)

    def marker(self, process, expected):
        ready, _, _ = select.select([process.stderr], [], [], 5)
        self.assertTrue(ready, "receiver never reached the specified fault boundary")
        self.assertEqual(process.stderr.readline(), expected + b"\n")

    def rows(self):
        with sqlite3.connect(self.db) as connection:
            return connection.execute("SELECT * FROM backend_requests ORDER BY effect_id").fetchall()

    def test_init_is_explicit_private_and_never_overwrites_existing_state(self):
        self.assertEqual(os.stat(self.db).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.db.parent).st_mode & 0o777, 0o700)
        response, status = self.invoke("init")
        self.assertEqual((status, response["error"], response["store_id"]), (2, "store_exists", None))
        result, status = self.send(self.request("lookup"))
        self.assertEqual(status, 0)
        self.assert_receipt(result, "unknown")
        self.assertEqual(result["disposition"], "unknown")
        self.assertTrue(all(result[key] is None for key in
                            ("backend_id", "admission_id", "plan_digest", "execution_deadline")))

    def test_concurrent_processes_allocate_one_immutable_identity(self):
        request = self.request()
        processes = [self.spawn(request) for _ in range(4)]
        responses = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual((process.returncode, stderr), (0, b""), stdout)
            responses.append(json.loads(stdout))
        self.assertEqual(len({process.pid for process in processes}), 4)
        self.assertEqual(len({response["backend_id"] for response in responses}), 1)
        self.assertEqual(sorted(response["disposition"] for response in responses),
                         ["created", "existing", "existing", "existing"])
        self.assertEqual(len(self.rows()), 1)
        for response in responses:
            self.assert_receipt(response, "accepted")

    def test_changed_binding_conflicts_without_replacing_original_receipt(self):
        original = self.accepted()
        stored = self.rows()
        self.assert_error(self.send(self.request(plan_digest="b" * 64)), "binding_conflict", 1)
        later = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        self.assert_error(self.send(self.request(execution_deadline=later)), "binding_conflict", 1)
        self.assert_error(self.send(self.request(admission_id="agent-admission:" + "b" * 64)),
                          "invalid_request")
        self.assertEqual(self.rows(), stored)
        response = self.accepted()
        self.assertEqual(response, {**original, "disposition": "existing"})

    def test_deadline_spelling_is_retained_and_different_spelling_conflicts(self):
        original = self.accepted()
        self.assertEqual(original["execution_deadline"], self.deadline)
        self.assert_error(self.send(self.request(execution_deadline=self.deadline.replace("Z", "+00:00"))),
                          "binding_conflict", 1)
        response = self.accepted()
        self.assertEqual(response, {**original, "disposition": "existing"})

    def test_unknown_effect_fence_survives_restart_and_refuses_delayed_create(self):
        fenced, status = self.send(self.request("fence"))
        self.assertEqual(status, 0)
        self.assert_receipt(fenced, "fenced")
        self.assertTrue(all(fenced[key] is None for key in
                            ("backend_id", "admission_id", "plan_digest", "execution_deadline")))
        original_rows = self.rows()
        for _ in range(2):
            self.assert_error(self.send(self.request()), "effect_fenced", 1)
            lookup, status = self.send(self.request("lookup"))
            self.assertEqual(status, 0)
            self.assertEqual(lookup, {**fenced, "operation": "lookup"})
            repeated, status = self.send(self.request("fence"))
            self.assertEqual((status, repeated), (0, fenced))
            self.assertEqual(self.rows(), original_rows)

    def test_fence_after_acceptance_retains_identity_without_claiming_termination(self):
        original = self.accepted()
        fenced, status = self.send(self.request("fence"))
        self.assertEqual(status, 0)
        self.assert_receipt(fenced, "fenced")
        for key in ("backend_id", "admission_id", "plan_digest", "execution_deadline"):
            self.assertEqual(fenced[key], original[key])
        self.assert_error(self.send(self.request()), "effect_fenced", 1)
        lookup, status = self.send(self.request("lookup"))
        self.assertEqual((status, lookup), (0, {**fenced, "operation": "lookup"}))

    def test_create_and_fence_from_competing_processes_always_retain_permanent_fence(self):
        creating = self.spawn(self.request())
        fencing = self.spawn(self.request("fence"))
        create_out, create_error = creating.communicate(timeout=8)
        fence_out, fence_error = fencing.communicate(timeout=8)
        self.assertEqual((create_error, fence_error, fencing.returncode), (b"", b"", 0))
        self.assertIn(creating.returncode, (0, 1))
        created = json.loads(create_out)
        fenced = json.loads(fence_out)
        self.assert_receipt(fenced, "fenced")
        if creating.returncode == 0:
            self.assertEqual(fenced["backend_id"], created["backend_id"])
        else:
            self.assertEqual(created["error"], "effect_fenced")
            self.assertIsNone(fenced["backend_id"])
        self.assert_error(self.send(self.request()), "effect_fenced", 1)

    def test_sigkill_after_commit_before_reply_recovers_same_identity_in_fresh_process(self):
        process = self.spawn(self.request(), barrier=True)
        self.marker(process, b"COMMITTED")
        before = self.rows()
        self.assertEqual(len(before), 1)
        self.assertIsNone(process.poll())
        process.kill()
        lost_stdout, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.assertEqual(lost_stdout, b"", "ordinary create reply must actually be lost")
        fresh = self.spawn(self.request())
        stdout, stderr = fresh.communicate(timeout=8)
        self.assertEqual((fresh.returncode, stderr), (0, b""))
        recovered = json.loads(stdout)
        self.assertNotEqual(process.pid, fresh.pid)
        self.assert_receipt(recovered, "accepted")
        self.assertEqual(recovered["disposition"], "existing")
        self.assertEqual(recovered["backend_id"], before[0][2])
        self.assertEqual(self.rows(), before)
        lookup, status = self.send(self.request("lookup"))
        self.assertEqual((status, lookup), (0, {**recovered, "operation": "lookup"}))
        evidence_dir = os.environ.get("AGENT_BACKEND_EVIDENCE_DIR")
        if evidence_dir:
            directory = Path(evidence_dir)
            directory.mkdir(parents=True, exist_ok=True)
            evidence = {
                "schema": "bizkit.agent-backend-crash-evidence.v1",
                "source_revision": os.environ.get("AGENT_LAUNCH_SOURCE_REVISION"),
                "killed_pid": process.pid, "recovered_pid": fresh.pid,
                "signal": "SIGKILL", "ordinary_reply_bytes": len(lost_stdout),
                "store_id": self.store_id, "backend_id_before": before[0][2],
                "backend_id_after": recovered["backend_id"],
                "allocation_count_before": len(before), "allocation_count_after": len(self.rows()),
                "execution_started": False, "termination_verified": False,
            }
            (directory / "receiver-sigkill-recovery.json").write_text(json.dumps(evidence, indent=2) + "\n")

    def test_deadline_expiry_refuses_create_and_does_not_allocate(self):
        expired = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        self.assert_error(self.send(self.request(execution_deadline=expired)), "deadline_expired", 1)
        self.assertEqual(self.rows(), [])

    def test_deadline_is_observed_after_database_lock_wait(self):
        connection = sqlite3.connect(self.db, isolation_level=None)
        self.addCleanup(connection.close)
        connection.execute("BEGIN IMMEDIATE")
        until = datetime.now(timezone.utc) + timedelta(milliseconds=800)
        process = self.spawn(self.request(execution_deadline=until.isoformat()), barrier=True, mode="lock")
        self.marker(process, b"LOCK_REQUEST")
        self.assertLess(datetime.now(timezone.utc), until, "fixture must reach lock while deadline is live")
        while datetime.now(timezone.utc) <= until:
            time.sleep(0.01)
        connection.execute("COMMIT")
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(stderr, b"")
        self.assert_error((json.loads(stdout), process.returncode), "deadline_expired", 1)
        self.assertEqual(self.rows(), [])

    def test_database_busy_is_bounded_and_never_success(self):
        with sqlite3.connect(self.db, isolation_level=None) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                self.assert_error(self.send(self.request()), "database_busy")
            finally:
                connection.execute("ROLLBACK")
        self.assertEqual(self.rows(), [])

    def test_missing_state_never_recreates_and_replacement_identity_is_refused(self):
        original = self.accepted()
        moved = self.db.with_suffix(".retained")
        self.db.rename(moved)
        self.assert_error(self.send(self.request()), "store_missing")
        self.assertFalse(self.db.exists())
        replacement, status = self.invoke("init")
        self.assertEqual(status, 0)
        self.assertNotEqual(replacement["store_id"], self.store_id)
        self.assert_error(self.send(self.request()), "store_identity_mismatch")
        self.assertEqual(self.rows(), [])
        restored, status = self.send(self.request("lookup"), db=moved)
        self.assertEqual(status, 0)
        self.assertEqual(restored["backend_id"], original["backend_id"])

    def test_private_paths_reject_symlinks_hardlinks_and_loose_permissions(self):
        link = self.db.parent / "alias.sqlite"
        link.symlink_to(self.db)
        self.assert_error(self.send(self.request(), db=link), "invalid_store")
        link.unlink()
        os.link(self.db, link)
        self.assert_error(self.send(self.request()), "invalid_store")
        link.unlink()
        os.chmod(self.db, 0o644)
        self.assert_error(self.send(self.request()), "invalid_store")
        os.chmod(self.db, 0o600)
        os.chmod(self.db.parent, 0o755)
        self.assert_error(self.send(self.request()), "invalid_store")
        os.chmod(self.db.parent, 0o700)
        alias_directory = self.db.parent / "directory-alias"
        alias_directory.symlink_to(self.db.parent, target_is_directory=True)
        self.assert_error(self.send(self.request(), db=alias_directory / self.db.name), "invalid_store")

    def test_sql_triggers_preserve_store_identity_binding_and_tombstones(self):
        self.accepted()
        self.send(self.request("fence"))
        stored = self.rows()
        with sqlite3.connect(self.db) as connection:
            for sql in (
                "UPDATE store_metadata SET store_id='agent-backend-store:' || lower(hex(randomblob(16)))",
                "DELETE FROM store_metadata",
                "INSERT OR REPLACE INTO store_metadata VALUES(1,1,'replacement')",
                "UPDATE backend_requests SET plan_digest='replacement'",
                "UPDATE backend_requests SET state='accepted'",
                "DELETE FROM backend_requests",
                "INSERT OR REPLACE INTO backend_requests(effect_id,state) VALUES('agent-run:fixture-1','fenced')",
            ):
                with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                    connection.execute(sql)
        self.assertEqual(self.rows(), stored)

    def test_closed_bounded_request_protocol_refuses_untrusted_shapes(self):
        cases = [
            self.request(extra="callback"), self.request(operation="execute"),
            self.request(effect_id="agent-run:../elsewhere"),
            self.request(plan_digest="A" * 64), self.request(plan_digest=False),
            self.request(execution_deadline="2026-01-01T00:00:00+01:00"),
            self.request(execution_deadline="2026-02-30T00:00:00Z"),
            self.request(execution_deadline="2026-01-01T00:00:00.1234567Z"),
            {**self.request("lookup"), "plan_digest": "a" * 64},
            {key: value for key, value in self.request().items() if key != "admission_id"},
        ]
        for request in cases:
            with self.subTest(request=request):
                self.assert_error(self.send(request), "invalid_request")
        for raw in (b"{} {}", b"\xff", b"[]", b"x" * 8193,
                    b'{"store_id":"x","store_id":"y"}'):
            with self.subTest(raw=raw[:50]):
                response, status = self.invoke("request", raw=raw)
                self.assertEqual((status, response), (2, {"schema": receiver.ERROR_SCHEMA,
                                 "error": "invalid_request", "store_id": None}))
        self.assertEqual(self.rows(), [])


if __name__ == "__main__":
    unittest.main()
