"""Sender/receiver databases and concurrent PostgreSQL backends, no transport."""
import base64
import hashlib
import json
import subprocess
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from halaqa_outbox_draft import OutboxDraft, LocalReceiptPeer
from halaqa_receipt_draft import ReceiptDraft, ROOT
from test_halaqa_receipt_draft import ReceiptTestCase


class TwoDatabaseTestCase(ReceiptTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.admin((ROOT / "tools/halaqa_receipt_draft/outbox.sql").read_text())
        cls.admin("""GRANT EXECUTE ON FUNCTION
            halaqa_receipt_draft.stage_intent(bytea,bytea,jsonb),
            halaqa_receipt_draft.get_intent(bigint),
            halaqa_receipt_draft.begin_attempt(bigint),
            halaqa_receipt_draft.finish_attempt(bigint,bigint,jsonb),
            halaqa_receipt_draft.pending_intents(text,text,bigint,integer)
            TO halaqa_receipt_test_client;""")
        cls.sender = OutboxDraft(cls.database, cls.env)
        # Separate destination storage: sender completion never shares a SQL
        # transaction with receiver receipt commit.
        cls.receiver_database = "halaqa_receipt_test_peer"
        cls.run_process(["createdb", cls.receiver_database])
        cls.run_process(["psql", "-X", "-qAt", "--set=ON_ERROR_STOP=1", "--dbname", cls.receiver_database],
                        input=(ROOT / "tools/halaqa_receipt_draft/schema.sql").read_text() + """
            GRANT USAGE ON SCHEMA halaqa_receipt_draft TO halaqa_receipt_test_client;
            GRANT EXECUTE ON FUNCTION halaqa_receipt_draft.record_candidate(bytea,bytea,jsonb),
                halaqa_receipt_draft.lookup_receipt(text,text,text,bytea)
                TO halaqa_receipt_test_client;""")
        cls.receiver = ReceiptDraft(cls.receiver_database, cls.env)

    def peer(self, policy):
        return LocalReceiptPeer(self.receiver, policy)

    def receiver_rows(self, policy, candidate):
        message = json.loads(candidate)
        from halaqa_receipt_draft import sql_text
        query = ("SELECT count(*) FROM halaqa_receipt_draft.receipts WHERE message_id="
                 + sql_text(message["message_id"]) + " AND recipient=" + sql_text(policy["recipient"]))
        return int(self.run_process(["psql", "-X", "-qAt", "--dbname", self.receiver_database],
                                    input=query).stdout)


class OutboxAcceptanceTests(TwoDatabaseTestCase):
    def test_stage_retains_first_bytes_and_changed_content_evidence(self):
        wire, policy, candidate = self.fixture()
        original = self.sender.stage(wire, policy)
        resigned, policy2, same = self.fixture(issued_delta=-1)
        self.assertEqual(candidate, same)
        self.assertEqual(self.sender.stage(resigned, policy2), original)
        self.assertEqual(original["wire_hex"], wire.hex())
        self.assertEqual(original["test_policy"], policy)
        changed, _, different = self.fixture(whitespace=True)
        conflict = self.sender.stage(changed, policy)
        self.assertEqual(conflict["outcome"], "OUTBOUND_CONTENT_CONFLICT")
        self.assertEqual(self.sender.intent(original["intent_id"]), original)
        raw = self.admin("SELECT encode(candidate,'hex') || ':' || encode(signed_wire,'hex') "
                         "FROM halaqa_receipt_draft.outbound_conflicts WHERE intent_id="
                         + str(original["intent_id"]))
        self.assertEqual(raw, different.hex() + ":" + changed.hex())

    def test_all_invalid_vectors_stop_before_staging_sql(self):
        count = 0
        with patch.object(self.sender, "query", side_effect=AssertionError("database reached")):
            for vector in self.corpus["vectors"]:
                if vector["expected"] == "REFUSED_SIGNED_TEST":
                    with self.subTest(vector=vector["name"]), self.assertRaises(ValueError):
                        self.sender.stage(base64.b64decode(vector["wire_base64"]), vector["test_policy"])
                    count += 1
        self.assertEqual(count, 66)

    def test_concurrent_staging_has_one_immutable_intent(self):
        wire, policy, _ = self.fixture()
        barrier = threading.Barrier(8)

        def stage(_):
            barrier.wait(timeout=10)
            return self.sender.stage(wire, policy)

        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(stage, range(8)))
        self.assertTrue(all(item == results[0] for item in results))
        self.assertEqual(results[0]["generation"], 0)
        self.assertEqual(results[0]["state"], "PENDING_TEST_ONLY")

    def test_staging_rollback_has_no_partial_intent_or_work_row(self):
        wire, policy, _ = self.fixture()
        real_run = subprocess.run

        def abort(args, **kwargs):
            if args[0] == "psql":
                kwargs["input"] = kwargs["input"].replace("COMMIT;", "ROLLBACK; SELECT 1/0;")
            return real_run(args, **kwargs)

        with patch("halaqa_receipt_draft.subprocess.run", side_effect=abort):
            with self.assertRaises(subprocess.CalledProcessError):
                self.sender.stage(wire, policy)
        from halaqa_receipt_draft import sql_text
        self.assertEqual(self.admin("SELECT count(*) FROM halaqa_receipt_draft.outbound_intents "
                                   "WHERE message_id=" + sql_text(self._testMethodName)), "0")
        staged = self.sender.stage(wire, policy)
        self.assertEqual(staged["state"], "PENDING_TEST_ONLY")

    def test_two_database_delivery_commits_unknown_before_callback(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        peer = self.peer(policy)
        original_status = peer.status

        def inspect(*args):
            state = self.sender.intent(staged["intent_id"])
            self.assertEqual(state["state"], "UNKNOWN")
            self.assertEqual(state["generation"], 1)
            self.assertEqual(state["wire_hex"], wire.hex())
            return original_status(*args)

        with patch.object(peer, "status", side_effect=inspect):
            result = self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(result["state"], "CONFIRMED_TEST_ONLY")
        self.assertEqual(result["remote_receipt"]["candidate_sha256"], hashlib.sha256(candidate).hexdigest())
        with patch.object(peer, "status", side_effect=AssertionError("terminal work retried")):
            self.assertEqual(self.sender.advance(staged["intent_id"], peer, policy), result)
        self.assertEqual(self.receiver_rows(policy, candidate), 1)
        self.assertFalse(result["authority_verified"])
        self.assertFalse(result["production_receiver"])

    def test_lost_receiver_ack_reconciles_after_expiry_without_resending(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        peer = self.peer(policy)
        receive = peer.receive

        def lose(wire):
            receive(wire)
            raise OSError("receiver committed, response lost")

        with patch.object(peer, "receive", side_effect=lose):
            with self.assertRaises(OSError):
                self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        expired = {**policy, "now": json.loads(wire)["expires_at"], "revoked": True}
        peer.test_policy.update(expired)
        with patch.object(peer, "receive", side_effect=AssertionError("expired bytes resent")):
            result = self.sender.advance(staged["intent_id"], peer, expired)
        self.assertEqual(result["state"], "CONFIRMED_TEST_ONLY")
        self.assertEqual(result["wire_hex"], wire.hex())
        self.assertEqual(self.receiver_rows(policy, candidate), 1)

    def test_missing_expired_delivery_stays_unknown(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        expired = {**policy, "now": json.loads(wire)["expires_at"]}
        peer = self.peer(expired)
        with patch.object(peer, "receive", side_effect=AssertionError("expired wire sent")):
            with self.assertRaisesRegex(ValueError, "test_expiry"):
                self.sender.advance(staged["intent_id"], peer, expired)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_receiver_current_policy_cannot_be_replaced_by_sender_snapshot(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        peer = self.peer({**policy, "revoked": True})
        with self.assertRaisesRegex(ValueError, "test_key_revoked"):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_unavailable_peer_and_wrong_recipient_cannot_complete(self):
        wire, policy, _ = self.fixture()
        staged = self.sender.stage(wire, policy)
        peer = self.peer(policy)
        with patch.object(peer, "status", side_effect=OSError("partition")):
            with self.assertRaises(OSError):
                self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        wrong = self.peer({**policy, "recipient": "wrong-recipient"})
        with patch.object(wrong, "status", side_effect=AssertionError("wrong peer contacted")):
            with self.assertRaisesRegex(ValueError, "recipient mismatch"):
                self.sender.advance(staged["intent_id"], wrong, policy)
        self.assertEqual(self.sender.advance(staged["intent_id"], peer, policy)["state"], "CONFIRMED_TEST_ONLY")

    def test_remote_conflict_is_terminal_and_preserves_both_bindings(self):
        wire, policy, candidate = self.fixture()
        different, _, other_candidate = self.fixture(whitespace=True)
        remote = self.receiver.receive(different, policy)
        staged = self.sender.stage(wire, policy)
        result = self.sender.advance(staged["intent_id"], self.peer(policy), policy)
        self.assertEqual(result["state"], "REMOTE_CONFLICT")
        self.assertEqual(result["remote_receipt"]["candidate_sha256"], remote["candidate_sha256"])
        self.assertNotEqual(result["candidate_sha256"], remote["candidate_sha256"])
        self.assertEqual(self.sender.begin(staged["intent_id"]), result)
        self.assertEqual(self.receiver.receive(different, policy), remote)
        self.assertEqual(result["candidate_hex"], candidate.hex())
        self.assertEqual(self.lookup(policy, candidate)["status"], "NOT_FOUND")  # sender has no inbox row
        self.assertEqual(self.receiver_rows(policy, other_candidate), 1)

    def test_malformed_or_unbound_results_cannot_settle(self):
        wire, policy, _ = self.fixture()
        staged = self.sender.stage(wire, policy)
        claimed = self.sender.begin(staged["intent_id"])
        valid = self.receiver.receive(wire, policy)
        variants = [{**valid, field: value} for field, value in (
            ("sender", "another-sender"), ("recipient", "another-recipient"),
            ("message_id", "another-message"), ("candidate_sha256", "0" * 64),
            ("schema", "other"), ("authority_verified", True),
            ("authority_verified", 0), ("receipt_id", 9223372036854775808),
            ("production_receiver", True), ("receipt_id", True),
            ("status", "CONTENT_MISMATCH"), ("extra", "unreviewed"))]
        variants += [{k: v for k, v in valid.items() if k != "candidate_sha256"},
                     {"status": "NOT_FOUND", "authority_verified": False, "production_receiver": False}]
        for reply in variants:
            with self.subTest(reply=reply), self.assertRaises(subprocess.CalledProcessError):
                self.sender.finish(staged["intent_id"], claimed["generation"], reply)
            self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        self.assertEqual(self.sender.finish(staged["intent_id"], claimed["generation"], valid)["state"],
                         "CONFIRMED_TEST_ONLY")

    def test_malformed_not_found_cannot_trigger_transmission(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        peer = self.peer(policy)
        reply = {"status": "NOT_FOUND", "authority_verified": 0, "production_receiver": False}
        with patch.object(peer, "status", return_value=reply), \
             patch.object(peer, "receive", side_effect=AssertionError("malformed miss triggered send")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_late_callbacks_are_fenced_and_terminal_result_is_immutable(self):
        wire, policy, _ = self.fixture()
        staged = self.sender.stage(wire, policy)
        first = self.sender.begin(staged["intent_id"])
        second = self.sender.begin(staged["intent_id"])
        receipt = self.receiver.receive(wire, policy)
        stale = self.sender.finish(staged["intent_id"], first["generation"], receipt)
        self.assertEqual(stale["outcome"], "STALE_ATTEMPT")
        self.assertEqual(stale["state"], "UNKNOWN")
        current = self.sender.finish(staged["intent_id"], second["generation"], receipt)
        self.assertEqual(current["state"], "CONFIRMED_TEST_ONLY")
        self.sender.finish(staged["intent_id"], first["generation"], {"untrusted": True})
        self.assertEqual(self.sender.intent(staged["intent_id"]), current)
        with self.assertRaises(subprocess.CalledProcessError):
            self.admin("UPDATE halaqa_receipt_draft.outbound_delivery SET state='UNKNOWN',remote_receipt=NULL "
                       "WHERE intent_id=" + str(staged["intent_id"]))

    def test_pending_pages_are_bounded_scoped_and_rebuilt_from_sql(self):
        wire, policy, _ = self.fixture()
        first = self.sender.stage(wire, policy)
        wire2, policy2, _ = self.fixture(changes={"message_id": self._testMethodName + "-2"})
        second = self.sender.stage(wire2, policy2)
        self.sender.begin(first["intent_id"])
        items = self.sender.pending(policy["sender"], policy["recipient"], limit=1)["intents"]
        self.assertLessEqual(len(items), 1)
        # Isolate this test's rows using keyset positions; IDs are not a prefix
        # watermark, and every sweep must eventually wrap back to zero.
        items = self.sender.pending(policy["sender"], policy["recipient"], after=first["intent_id"] - 1)["intents"]
        self.assertEqual([i["intent_id"] for i in items], [first["intent_id"], second["intent_id"]])
        self.assertEqual(self.sender.pending("unknown-sender", policy["recipient"])["intents"], [])
        for limit in (0, 17, True):
            with self.assertRaises(ValueError):
                self.sender.pending(policy["sender"], policy["recipient"], limit=limit)
        self.sender.advance(first["intent_id"], self.peer(policy), policy)
        remaining = self.sender.pending(policy["sender"], policy["recipient"], after=first["intent_id"] - 1)["intents"]
        self.assertEqual([i["intent_id"] for i in remaining], [second["intent_id"]])

    def test_crash_recovery_retains_original_unknown_and_terminal_evidence(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        unknown = self.sender.begin(staged["intent_id"])
        self.control("stop", "-m", "immediate")
        self.start_server()
        self.assertEqual(self.sender.intent(staged["intent_id"]), unknown)
        result = self.sender.advance(staged["intent_id"], self.peer(policy), policy)
        self.control("stop", "-m", "immediate")
        self.start_server()
        self.assertEqual(self.sender.intent(staged["intent_id"]), result)
        self.assertEqual(self.receiver_rows(policy, candidate), 1)

    def test_lost_sender_completion_ack_never_reactivates_delivery(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        claimed = self.sender.begin(staged["intent_id"])
        receipt = self.receiver.receive(wire, policy)
        real_run = subprocess.run

        def lose(args, **kwargs):
            if args[0] == "psql":
                kwargs["input"] += "RESET ROLE; SELECT pg_terminate_backend(pg_backend_pid());\n"
            return real_run(args, **kwargs)

        with patch("halaqa_receipt_draft.subprocess.run", side_effect=lose):
            with self.assertRaises(subprocess.CalledProcessError):
                self.sender.finish(staged["intent_id"], claimed["generation"], receipt)
        retained = self.sender.intent(staged["intent_id"])
        self.assertEqual(retained["state"], "CONFIRMED_TEST_ONLY")
        with patch.object(LocalReceiptPeer, "status", side_effect=AssertionError("confirmed intent retried")):
            self.assertEqual(self.sender.advance(staged["intent_id"], self.peer(policy), policy), retained)
        self.assertEqual(self.receiver_rows(policy, candidate), 1)


if __name__ == "__main__":
    unittest.main()
