"""Real PostgreSQL acceptance in a fresh, locally owned, disposable cluster.

Requires PostgreSQL 16 binaries and OpenSSL. No production database is read or
modified; host/auth/database settings are overridden for this test cluster.
"""
from concurrent.futures import ThreadPoolExecutor
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from halaqa_receipt_draft import ReceiptDraft, ROOT, sql_bytes, sql_text


class ReceiptTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="halaqa_receipt_test_")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.data = Path(cls.directory.name) / "data"
        cls.log = Path(cls.directory.name) / "postgres.log"
        cls.bin = Path(os.environ.get("HALAQA_PG_BIN", "/usr/lib/postgresql/16/bin"))
        if not all((cls.bin / x).is_file() for x in ("initdb", "pg_ctl", "psql", "createdb")):
            raise RuntimeError("PostgreSQL 16 binaries required; set HALAQA_PG_BIN")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
        cls.env.update({"PATH": str(cls.bin) + os.pathsep + os.environ["PATH"],
                        "PGHOST": "127.0.0.1", "PGPORT": str(port),
                        "PGUSER": "testadmin", "PGSSLMODE": "disable"})
        cls.run_process([str(cls.bin / "initdb"), "-D", str(cls.data), "-U", "testadmin",
                         "-A", "trust", "--locale=C", "--encoding=UTF8"])
        cls.options = (f"-h 127.0.0.1 -p {port} -k '' -c fsync=on "
                       "-c synchronous_commit=on -c full_page_writes=on -c jit=off")
        cls.start_server()
        cls.addClassCleanup(lambda: cls.control("stop", "-m", "immediate"))
        cls.database = "halaqa_receipt_test_acceptance"
        cls.run_process(["createdb", cls.database])
        cls.admin((ROOT / "tools/halaqa_receipt_draft/schema.sql").read_text())
        cls.admin("""CREATE ROLE halaqa_receipt_test_client NOLOGIN;
            GRANT USAGE ON SCHEMA halaqa_receipt_draft TO halaqa_receipt_test_client;
            GRANT EXECUTE ON FUNCTION halaqa_receipt_draft.record_candidate(bytea,bytea,jsonb),
              halaqa_receipt_draft.lookup_receipt(text,text,text,bytea)
              TO halaqa_receipt_test_client;""")
        cls.client = ReceiptDraft(cls.database, cls.env)
        cls.corpus = json.loads((ROOT / "tools/halaqa_federation_draft/signed-vectors.json").read_text())

    @classmethod
    def run_process(cls, args, **kwargs):
        return subprocess.run(args, env=cls.env, text=True, capture_output=True,
                              check=True, timeout=30, **kwargs)

    @classmethod
    def control(cls, operation, *args):
        return cls.run_process([str(cls.bin / "pg_ctl"), "-D", str(cls.data),
                                "-w", operation, *args])

    @classmethod
    def start_server(cls):
        return cls.control("start", "-l", str(cls.log), "-o", cls.options)

    @classmethod
    def admin(cls, sql):
        return cls.run_process(["psql", "-X", "-qAt", "--set=ON_ERROR_STOP=1",
                                "--dbname", cls.database], input=sql).stdout.strip()

    def fixture(self, *, changes=None, policy_changes=None, issued_delta=0, whitespace=False):
        vector = self.corpus["vectors"][0]
        envelope = json.loads(base64.b64decode(vector["wire_base64"]))
        message = json.loads(base64.b64decode(envelope["candidate"]))
        message["message_id"] = self._testMethodName
        message.update(changes or {})
        policy = copy.deepcopy(vector["test_policy"])
        policy.update({k: message[k] for k in ("sender", "recipient", "halaqa_id", "charter_hash", "epoch")})
        policy.update(policy_changes or {})
        candidate = json.dumps(message, separators=(",", ":")).encode()
        if whitespace:
            candidate += b"\n"
        envelope["candidate"] = base64.b64encode(candidate).decode()
        envelope["issued_at"] += issued_delta
        envelope["expires_at"] += issued_delta
        transcript = self.client.signed.transcript(candidate, envelope["key_id"],
                                                   envelope["issued_at"], envelope["expires_at"])
        # Disclosed fixture seed, never an operational credential.
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "key.der"
            msg = Path(directory) / "message"
            key.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + bytes(range(32)))
            msg.write_bytes(transcript)
            signature = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(key),
                                        "-keyform", "DER", "-rawin", "-in", str(msg)],
                                       check=True, capture_output=True, timeout=5).stdout
        envelope["signature"] = base64.b64encode(signature).decode()
        return json.dumps(envelope).encode(), policy, candidate

    def lookup(self, policy, candidate):
        message = json.loads(candidate)
        return self.client.status(policy["recipient"], policy["sender"], message["message_id"],
                                  hashlib.sha256(candidate).digest())

    def count(self, table, receipt_id):
        assert table in ("receipts", "conflicts")
        return int(self.admin(f"SELECT count(*) FROM halaqa_receipt_draft.{table} "
                              f"WHERE receipt_id={int(receipt_id)}"))


class ReceiptAcceptanceTests(ReceiptTestCase):
    def test_committed_receipt_survives_lost_ack_and_expiry(self):
        wire, policy, candidate = self.fixture()
        real_run = subprocess.run

        def lose_response(args, **kwargs):
            if args[0] == "psql":
                kwargs["input"] += "RESET ROLE; SELECT pg_terminate_backend(pg_backend_pid());\n"
            return real_run(args, **kwargs)

        with patch("halaqa_receipt_draft.subprocess.run", side_effect=lose_response):
            with self.assertRaises(subprocess.CalledProcessError):
                self.client.receive(wire, policy)
        retained = self.lookup(policy, candidate)
        self.assertEqual(retained["status"], "STORED_TEST_ONLY")
        self.assertEqual(self.client.receive(wire, policy), retained)
        expired = {**policy, "now": json.loads(wire)["expires_at"]}
        with self.assertRaisesRegex(ValueError, "test_expiry"):
            self.client.receive(wire, expired)
        self.assertEqual(self.lookup(expired, candidate), retained)
        with self.assertRaisesRegex(ValueError, "test_key_revoked"):
            self.client.receive(wire, {**policy, "revoked": True})
        self.assertEqual(self.lookup({**policy, "revoked": True}, candidate), retained)

    def test_rollback_leaves_no_receipt(self):
        wire, policy, candidate = self.fixture()
        real_run = subprocess.run

        def abort_before_commit(args, **kwargs):
            if args[0] == "psql":
                kwargs["input"] = kwargs["input"].replace("COMMIT;", "ROLLBACK; SELECT 1/0;")
            return real_run(args, **kwargs)

        with patch("halaqa_receipt_draft.subprocess.run", side_effect=abort_before_commit):
            with self.assertRaises(subprocess.CalledProcessError):
                self.client.receive(wire, policy)
        self.assertEqual(self.lookup(policy, candidate)["status"], "NOT_FOUND")
        self.assertEqual(self.client.receive(wire, policy)["status"], "STORED_TEST_ONLY")

    def test_changed_exact_bytes_are_retained_as_conflict(self):
        wire, policy, candidate = self.fixture()
        original = self.client.receive(wire, policy)
        changed, _, different = self.fixture(whitespace=True)
        self.assertEqual(json.loads(candidate), json.loads(different))
        conflict = self.client.receive(changed, policy)
        self.assertEqual(conflict["status"], "CONTENT_CONFLICT")
        self.assertEqual(conflict["receipt_id"], original["receipt_id"])
        self.assertEqual(self.client.receive(changed, policy), conflict)
        self.assertEqual(self.count("conflicts", original["receipt_id"]), 1)
        raw = self.admin("SELECT encode(candidate,'hex') || ':' || encode(signed_wire,'hex') "
                         "FROM halaqa_receipt_draft.conflicts WHERE receipt_id=" + str(original["receipt_id"]))
        self.assertEqual(raw, different.hex() + ":" + changed.hex())
        self.assertEqual(self.client.receive(wire, policy), original)
        self.assertEqual(self.lookup(policy, different)["status"], "CONTENT_MISMATCH")

    def test_conflict_rolls_back_atomically(self):
        wire, policy, candidate = self.fixture()
        original = self.client.receive(wire, policy)
        changed, _, _ = self.fixture(whitespace=True)
        real_run = subprocess.run

        def abort(args, **kwargs):
            if args[0] == "psql":
                kwargs["input"] = kwargs["input"].replace("COMMIT;", "ROLLBACK; SELECT 1/0;")
            return real_run(args, **kwargs)

        with patch("halaqa_receipt_draft.subprocess.run", side_effect=abort):
            with self.assertRaises(subprocess.CalledProcessError):
                self.client.receive(changed, policy)
        self.assertEqual(self.count("conflicts", original["receipt_id"]), 0)
        self.assertEqual(self.lookup(policy, candidate), original)
        self.assertEqual(self.client.receive(changed, policy)["status"], "CONTENT_CONFLICT")

    def test_resigning_candidate_returns_original_and_keeps_first_evidence(self):
        wire, policy, candidate = self.fixture()
        original = self.client.receive(wire, policy)
        resigned, policy2, same = self.fixture(issued_delta=-1)
        self.assertNotEqual(wire, resigned)
        self.assertEqual(candidate, same)
        self.assertEqual(self.client.receive(resigned, policy2), original)
        saved = self.admin("SELECT encode(signed_wire,'hex') FROM halaqa_receipt_draft.receipts "
                           "WHERE receipt_id=" + str(original["receipt_id"]))
        self.assertEqual(saved, wire.hex())

    def race(self, deliveries):
        barrier = threading.Barrier(len(deliveries))

        def deliver(item):
            barrier.wait(timeout=10)
            return self.client.receive(*item)

        with ThreadPoolExecutor(max_workers=len(deliveries)) as pool:
            return list(pool.map(deliver, deliveries))

    def test_concurrent_identical_deliveries_have_one_result(self):
        wire, policy, _ = self.fixture()
        results = self.race([(wire, policy)] * 8)
        self.assertTrue(all(result == results[0] for result in results))
        self.assertEqual(self.count("receipts", results[0]["receipt_id"]), 1)
        self.assertEqual(self.count("conflicts", results[0]["receipt_id"]), 0)

    def test_concurrent_different_content_has_one_winner_and_retained_conflict(self):
        wire, policy, candidate = self.fixture()
        changed, _, different = self.fixture(whitespace=True)
        results = self.race([(wire, policy), (changed, policy)] * 4)
        self.assertEqual({r["status"] for r in results}, {"STORED_TEST_ONLY", "CONTENT_CONFLICT"})
        self.assertEqual(len({r["receipt_id"] for r in results}), 1)
        self.assertEqual(self.count("conflicts", results[0]["receipt_id"]), 1)
        hashes = {hashlib.sha256(candidate).hexdigest(), hashlib.sha256(different).hexdigest()}
        self.assertIn(results[0]["candidate_sha256"], hashes)
        for r in results:
            if r["status"] == "CONTENT_CONFLICT":
                self.assertEqual({r["candidate_sha256"], r["attempted_sha256"]}, hashes)

    def test_actor_and_recipient_isolation_but_epoch_cannot_reset_id(self):
        wire, policy, _ = self.fixture()
        original = self.client.receive(wire, policy)
        for changes in ({"sender": "other-actor"}, {"recipient": "other-recipient"},
                        {"recipient": policy["recipient"].swapcase()}):
            changed, bound, _ = self.fixture(changes=changes)
            receipt = self.client.receive(changed, bound)
            self.assertEqual(receipt["status"], "STORED_TEST_ONLY")
            self.assertNotEqual(receipt["receipt_id"], original["receipt_id"])
        changed, bound, _ = self.fixture(changes={"epoch": policy["epoch"] + 1})
        self.assertEqual(self.client.receive(changed, bound)["status"], "CONTENT_CONFLICT")

    def test_all_refused_signed_vectors_stop_before_database(self):
        count = 0
        with patch.object(self.client, "query", side_effect=AssertionError("database reached")):
            for vector in self.corpus["vectors"]:
                if vector["expected"] == "REFUSED_SIGNED_TEST":
                    with self.subTest(name=vector["name"]), self.assertRaises(ValueError):
                        self.client.receive(base64.b64decode(vector["wire_base64"]), vector["test_policy"])
                    count += 1
        self.assertEqual(count, 66)

    def test_database_crash_recovery_preserves_receipt_and_conflict(self):
        wire, policy, candidate = self.fixture()
        original = self.client.receive(wire, policy)
        changed, _, _ = self.fixture(whitespace=True)
        conflict = self.client.receive(changed, policy)
        self.control("stop", "-m", "immediate")
        self.start_server()
        self.assertEqual(self.lookup(policy, candidate), original)
        self.assertEqual(self.client.receive(wire, policy), original)
        self.assertEqual(self.client.receive(changed, policy), conflict)
        self.assertEqual(self.count("conflicts", original["receipt_id"]), 1)

    def test_database_unavailable_cannot_emit_receipt(self):
        wire, policy, candidate = self.fixture()
        self.control("stop", "-m", "immediate")
        try:
            with self.assertRaises(subprocess.CalledProcessError):
                self.client.receive(wire, policy)
        finally:
            self.start_server()
        self.assertEqual(self.lookup(policy, candidate)["status"], "NOT_FOUND")
        self.assertEqual(self.client.receive(wire, policy)["status"], "STORED_TEST_ONLY")

    def test_immutable_rows_and_test_role_restrictions(self):
        wire, policy, candidate = self.fixture()
        original = self.client.receive(wire, policy)
        for table in ("receipts", "conflicts"):
            for sql in (f"UPDATE halaqa_receipt_draft.{table} SET candidate=candidate;",
                        f"DELETE FROM halaqa_receipt_draft.{table};",
                        f"TRUNCATE halaqa_receipt_draft.{table} CASCADE;"):
                with self.subTest(sql=sql), self.assertRaises(subprocess.CalledProcessError):
                    self.admin(sql)
            with self.assertRaises(subprocess.CalledProcessError):
                self.admin(f"SET ROLE halaqa_receipt_test_client; SELECT * FROM halaqa_receipt_draft.{table};")
        with self.assertRaises(subprocess.CalledProcessError):
            self.admin("SET ROLE halaqa_receipt_test_client; INSERT INTO halaqa_receipt_draft.receipts DEFAULT VALUES;")
        self.assertEqual(self.lookup(policy, candidate), original)
        self.assertFalse(original["authority_verified"])
        self.assertFalse(original["production_receiver"])

    def test_async_commit_and_unsupported_isolation_fail_closed(self):
        wire, policy, candidate = self.fixture()
        statement = ("SELECT halaqa_receipt_draft.record_candidate(" + sql_bytes(candidate)
                     + "," + sql_bytes(wire) + "," + sql_text(json.dumps(policy)) + "::jsonb);")
        for setting in ("SET LOCAL synchronous_commit=off;",
                        "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;"):
            with self.subTest(setting=setting), self.assertRaises(subprocess.CalledProcessError):
                self.admin("BEGIN;" + setting + statement + "COMMIT;")
        self.assertEqual(self.lookup(policy, candidate)["status"], "NOT_FOUND")

    def test_mismatched_or_missing_status_does_not_write(self):
        wire, policy, candidate = self.fixture()
        original = self.client.receive(wire, policy)
        self.assertEqual(self.client.status(policy["recipient"], "unknown", self._testMethodName,
                                            hashlib.sha256(candidate).digest())["status"], "NOT_FOUND")
        mismatch = self.client.status(policy["recipient"], policy["sender"], self._testMethodName, bytes(32))
        self.assertEqual(mismatch["status"], "CONTENT_MISMATCH")
        self.assertEqual(self.count("conflicts", original["receipt_id"]), 0)


if __name__ == "__main__":
    unittest.main()
