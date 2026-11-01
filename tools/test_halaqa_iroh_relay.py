"""Controlled HTTPS relay with explicit trust roots and no direct IP transport."""
import json
import copy
import os
import selectors
import signal
import subprocess
import unittest
from pathlib import Path

from halaqa_iroh_draft import IrohReceiptPeer, IrohReceiverFixture, strict_json, check_path
from test_halaqa_iroh_draft import IrohTestCase
from halaqa_receipt_draft import ROOT
from check_halaqa_two_hosts import initialize, compare_reports, read_json


def certificates(directory, run):
    """Generate a private CA and an IP-SAN relay certificate, not a TLS bypass."""
    directory = Path(directory)
    ca_key, ca_pem = directory / "ca.key", directory / "ca.pem"
    leaf_key, leaf_pem, csr = directory / "leaf.key", directory / "leaf.pem", directory / "leaf.csr"
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=Halaqa fixture CA", "-addext", "basicConstraints=critical,CA:TRUE",
         "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", str(ca_key), "-out", str(ca_pem)])
    run(["openssl", "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
         "-subj", "/CN=127.0.0.1", "-keyout", str(leaf_key), "-out", str(csr)])
    ext = directory / "relay.ext"
    ext.write_text("subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n")
    run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca_pem), "-CAkey", str(ca_key),
         "-CAcreateserial", "-days", "1", "-sha256", "-extfile", str(ext), "-out", str(leaf_pem)])
    outputs = {}
    for label, pem in (("ca_file", ca_pem), ("cert_file", leaf_pem)):
        path = directory / (label + ".der")
        run(["openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(path)])
        outputs[label] = str(path)
    key = directory / "tls-key.der"
    run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(leaf_key), "-outform", "DER", "-out", str(key)])
    key.chmod(0o600)
    outputs["key_file"] = str(key)
    return outputs


class RelayFixture:
    def __init__(self, binary, certs, allowed):
        self.process = subprocess.Popen([str(binary), "relay-server"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.process.stdin.write(json.dumps({"cert_file": certs["cert_file"], "key_file": certs["key_file"],
                                             "allowed_endpoints": allowed}).encode() + b"\n")
        self.process.stdin.flush()
        import selectors
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=10):
                self.close()
                raise RuntimeError("relay readiness timeout")
        ready = strict_json(self.process.stdout.readline(2048), 2048)
        if ready["event"] != "relay_ready" or ready["tls"] is not True:
            self.close()
            raise ValueError("invalid relay readiness")
        self.settings = {"url": ready["url"], "ca_file": certs["ca_file"]}

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.write(b'{"op":"stop"}\n')
            self.process.stdin.flush()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()


# Reuse setup helpers without inheriting/rerunning the seven direct tests.
class RelayAcceptanceTests(IrohTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cert_dir = Path(cls.directory.name) / "certs"
        cert_dir.mkdir()
        cls.certs = certificates(cert_dir, cls.run_process)

    def transport(self, policy, relay=None):
        if relay is None:
            relay = RelayFixture(self.binary, self.certs, [self.client_id, self.server_id])
            self.addCleanup(relay.close)
        server = IrohReceiverFixture(self.binary, self.server_key, self.client_id,
                                     self.receiver, policy, relay.settings)
        self.addCleanup(server.close)
        peer = IrohReceiptPeer(self.binary, self.client_key, server.address,
                               policy["sender"], policy["recipient"], relay.settings)
        return relay, server, peer

    def test_relay_delivery_has_selected_relay_stream_traffic_and_zero_ip_sockets(self):
        wire, policy, candidate = self.fixture()
        _, server, peer = self.transport(policy)
        staged = self.sender.stage(wire, policy)
        result = self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(result["state"], "CONFIRMED_TEST_ONLY")
        self.assertEqual(self.receiver_rows(policy, candidate), 1)
        self.assertEqual(len(server.path_evidence), 2)
        self.assertEqual(len(peer.path_evidence), 2)
        for value in server.path_evidence + peer.path_evidence:
            self.assertEqual(value["mode"], "relay_only")
            self.assertEqual(value["ip_bound_sockets"], 0)
            self.assertTrue(all(p["kind"] == "relay" for p in value["paths"]))
            self.assertTrue(any(p["selected"] and p["stream_rx"] > 0 for p in value["paths"]))

    def test_untrusted_relay_certificate_never_confirms_sender(self):
        wire, policy, candidate = self.fixture()
        _, server, peer = self.transport(policy)
        wrong_dir = Path(self.directory.name) / "wrong-ca"
        wrong_dir.mkdir(exist_ok=True)
        wrong = certificates(wrong_dir, self.run_process)
        peer.relay = {**peer.relay, "ca_file": wrong["ca_file"]}
        staged = self.sender.stage(wire, policy)
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(server.requests, [])
        self.assertEqual(self.receiver_rows(policy, candidate), 0)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")

    def test_relay_rejects_unknown_endpoint_before_receiver_callback(self):
        wire, policy, candidate = self.fixture()
        _, server, peer = self.transport(policy)
        peer.key_file = str(self.intruder_key)
        with self.assertRaises(subprocess.CalledProcessError):
            peer.receive(wire)
        self.assertEqual(server.requests, [])
        self.assertEqual(self.receiver_rows(policy, candidate), 0)

    def test_relay_outage_and_restart_reconcile_original_committed_intent(self):
        wire, policy, candidate = self.fixture()
        relay, server, peer = self.transport(policy)
        staged = self.sender.stage(wire, policy)
        server.drop_next_delivery_reply = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.receiver_rows(policy, candidate), 1)
        server.close()
        relay.close()
        with self.assertRaises(subprocess.CalledProcessError):
            self.sender.advance(staged["intent_id"], peer, policy)
        self.assertEqual(self.sender.intent(staged["intent_id"])["state"], "UNKNOWN")
        expired = {**policy, "now": json.loads(wire)["expires_at"], "revoked": True}
        _, recovered_server, recovered_peer = self.transport(expired)
        result = self.sender.advance(staged["intent_id"], recovered_peer, expired)
        self.assertEqual(result["state"], "CONFIRMED_TEST_ONLY")
        self.assertEqual(result["wire_hex"], wire.hex())
        self.assertEqual([op for _, op, _ in recovered_server.requests], ["status"])
        self.assertEqual(self.receiver_rows(policy, candidate), 1)

    def test_mixed_direct_and_relay_target_cannot_bypass_relay_profile(self):
        wire, policy, _ = self.fixture()
        _, server, peer = self.transport(policy)
        peer.target = {**peer.target, "addrs": peer.target["addrs"] + [{"Ip": "127.0.0.1:1"}]}
        with self.assertRaises(subprocess.CalledProcessError):
            peer.receive(wire)
        self.assertEqual(server.requests, [])

    def test_missing_or_direct_path_evidence_cannot_pass_as_relay(self):
        relay = {"url": "https://127.0.0.1:1/", "ca_file": "unused"}
        for value in ({}, {"mode": "direct", "ip_bound_sockets": 1, "paths": []},
                      {"mode": "relay_only", "ip_bound_sockets": 0, "paths": []}):
            with self.assertRaises(ValueError):
                check_path(value, relay)

    def test_operator_roles_rehearse_on_one_host_without_claiming_host_independence(self):
        directory = Path(self.directory.name) / "role-rehearsal"
        directory.mkdir()
        sender = initialize(directory / "sender", "sender", self.binary)
        receiver = initialize(directory / "receiver", "receiver", self.binary)
        relay = RelayFixture(self.binary, self.certs, [sender["endpoint"], receiver["endpoint"]])
        self.addCleanup(relay.close)
        runner = str(ROOT / "tools/check_halaqa_two_hosts.py")
        revision = "1" * 40  # Local rehearsal label, never reported as a verified Git commit.
        common = ["--relay-url", relay.settings["url"], "--ca-file", relay.settings["ca_file"], "--revision", revision, "--local-rehearsal"]
        import sys
        receiver_report = directory / "receiver-report.json"
        args = [sys.executable, runner, "--binary", str(self.binary), "serve", "--identity-dir", str(directory / "receiver"),
                "--peer-public", str(directory / "sender/public.json"), "--host-label", "same-host-receiver-role",
                "--report", str(receiver_report), "--duration", "60", *common]
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=15), "receiver role did not become ready")
            self.assertEqual(strict_json(process.stdout.readline(), 2048)["event"], "receiver_ready")
            sender_report = directory / "sender-report.json"
            result = subprocess.run([sys.executable, runner, "--binary", str(self.binary), "send",
                "--identity-dir", str(directory / "sender"), "--peer-public", str(directory / "receiver/public.json"),
                "--host-label", "same-host-sender-role", "--report", str(sender_report), *common],
                capture_output=True, text=True, timeout=50)
            self.assertEqual(result.returncode, 0, result.stderr)
            process.send_signal(signal.SIGINT)
            _, error = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, error.decode())
            s, r = read_json(sender_report), read_json(receiver_report)
            checked = compare_reports(s, r, revision)
            self.assertEqual(checked["result"], "PAIR_CONSISTENT_HOST_PROVENANCE_UNVERIFIED")
            self.assertIs(checked["checkout_verified"], False)
            self.assertIs(checked["separate_hosts_verified"], False)
            for field, value in (("wire_sha256", "0" * 64), ("peer_endpoint", "wrong-endpoint"),
                                 ("implementation_revision", "2" * 40), ("delivery_count", 2)):
                changed = copy.deepcopy(r)
                changed[field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    compare_reports(s, changed, revision)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=10)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()


if __name__ == "__main__":
    unittest.main()
