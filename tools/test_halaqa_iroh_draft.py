"""Real direct Iroh/QUIC loopback sidecars and separate PostgreSQL databases."""
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import unittest

from halaqa_iroh_draft import IrohReceiptPeer, IrohReceiverFixture, identity, strict_json
from halaqa_receipt_draft import ROOT
from test_halaqa_outbox_draft import TwoDatabaseTestCase


class IrohTestCase(TwoDatabaseTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.binary = Path(os.environ.get("HALAQA_IROH_BINARY",
            str(ROOT / "tools/halaqa_iroh_draft_rs/target/debug/halaqa-iroh-delivery-experiment")))
        if not cls.binary.is_file():
            raise RuntimeError("build the locked experimental Iroh crate first")
        cls.client_key = Path(cls.directory.name) / "client.key"
        cls.server_key = Path(cls.directory.name) / "server.key"
        cls.intruder_key = Path(cls.directory.name) / "intruder.key"
        for key in (cls.client_key, cls.server_key, cls.intruder_key):
            key.write_bytes(secrets.token_bytes(32))
            key.chmod(0o600)
        cls.client_id = identity(cls.binary, cls.client_key)
        cls.server_id = identity(cls.binary, cls.server_key)
        cls.intruder_id = identity(cls.binary, cls.intruder_key)

    def transport(self, policy):
        server = IrohReceiverFixture(self.binary, self.server_key, self.client_id, self.receiver, policy)
        self.addCleanup(server.close)
        peer = IrohReceiptPeer(self.binary, self.client_key, server.address, policy["sender"], policy["recipient"])
        return server, peer


class IrohAcceptanceTests(IrohTestCase):
    def test_direct_delivery_over_pinned_quic_without_application_http(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        server, peer = self.transport(policy)
        result = self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(result["state"], "CONFIRMED_TEST_ONLY")
        self.assertEqual(self.receiver_rows(policy, candidate), 1)
        self.assertEqual(result["wire_hex"], wire.hex())
        self.assertEqual({p for p, _, _ in server.requests}, {self.client_id})
        self.assertEqual([op for _, op, _ in server.requests], ["status", "deliver"])
        self.assertNotEqual(peer.challenges[0], peer.challenges[1])
        self.assertEqual(server.address["id"], self.server_id)
        self.assertTrue(all("Ip" in a and a["Ip"].startswith("127.0.0.1:") for a in server.address["addrs"]))

    def test_lost_quic_reply_reconciles_after_sidecar_restart_and_expiry(self):
        wire, policy, candidate = self.fixture()
        staged = self.sender.stage(wire, policy)
        server, peer = self.transport(policy)
        server.drop_next_delivery_reply = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        self.assertEqual(self.receiver_rows(policy, candidate), 1)
        expired = {**policy, "now": json.loads(wire)["expires_at"], "revoked": True}
        self.assertEqual([op for _, op, _ in server.requests], ["status", "deliver"])
        old_endpoint = server.address["id"]
        server.close()
        restarted, peer = self.transport(expired)
        self.assertEqual(restarted.address["id"], old_endpoint)
        result = self.sender.advance(staged["intent_id"], peer, expired)
        self.assertEqual(result["state"], "CONFIRMED_TEST_ONLY")
        self.assertEqual([op for _, op, _ in restarted.requests], ["status"])
        self.assertEqual(self.receiver_rows(policy, candidate), 1)

    def test_unconfigured_endpoint_never_reaches_host_or_receiver_store(self):
        wire, policy, candidate = self.fixture()
        server, peer = self.transport(policy)
        peer.key_file = str(self.intruder_key)
        staged = self.sender.stage(wire, policy)
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(server.requests, [])
        self.assertEqual(self.receiver_rows(policy, candidate), 0)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")

    def test_wrong_server_pin_cannot_supply_receipt(self):
        wire, policy, candidate = self.fixture()
        server, peer = self.transport(policy)
        peer.target = {**peer.target, "id": self.intruder_id}
        staged = self.sender.stage(wire, policy)
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(server.requests, [])
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_status_scope_and_stale_host_challenge_are_refused(self):
        wire, policy, candidate = self.fixture()
        server, peer = self.transport(policy)
        with self.assertRaises(subprocess.CalledProcessError):
            peer.request({"op": "status", "sender": "wrong-actor", "recipient": policy["recipient"],
                          "message_id": self._testMethodName, "candidate_sha256": hashlib.sha256(candidate).hexdigest()})
        self.assertEqual(server.requests, [])
        self.assertIsNone(server.process.poll())
        server.corrupt_next_challenge = True
        with self.assertRaises(subprocess.CalledProcessError):
            peer.status(policy["recipient"], policy["sender"], self._testMethodName,
                        hashlib.sha256(candidate).digest())
        self.assertNotEqual(server.process.wait(timeout=5), 0)
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_receiver_policy_and_invalid_signature_still_refuse_over_quic(self):
        wire, policy, candidate = self.fixture()
        _, peer = self.transport({**policy, "revoked": True})
        staged = self.sender.stage(wire, policy)
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.receiver_rows(policy, candidate), 0)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        _, verifying_peer = self.transport(policy)
        envelope = json.loads(wire)
        signature = bytearray(base64.b64decode(envelope["signature"]))
        signature[0] ^= 1
        envelope["signature"] = base64.b64encode(signature).decode()
        with self.assertRaises(subprocess.CalledProcessError):
            verifying_peer.receive(json.dumps(envelope).encode())
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_transport_json_and_wire_limits_fail_closed(self):
        wire, policy, _ = self.fixture()
        server, peer = self.transport(policy)
        with self.assertRaises(ValueError):
            peer.receive(bytes(12_289))
        for raw in (b'{"status":"NOT_FOUND","status":"STORED_TEST_ONLY"}', b'{"x":NaN}', b'['*9+b'0'+b']'*9):
            with self.assertRaises(ValueError):
                strict_json(raw, 8192)
        self.assertEqual(server.requests, [])
        # A malformed signed frame fits the transport bound but cannot become a receiver receipt.
        with self.assertRaises(subprocess.CalledProcessError):
            peer.receive(b'{}')


if __name__ == "__main__":
    unittest.main()
