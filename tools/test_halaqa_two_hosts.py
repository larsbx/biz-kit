"""Offline evidence-gate tests with temporary Git checkouts and invented reports.

These exercise refusal conditions, not Iroh traffic, PostgreSQL durability,
native build provenance or independent-host acceptance.
"""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_halaqa_two_hosts as runner


class ReportGateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="halaqa_report_gate_")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for path in runner.SOURCE_FILES:
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(runner.ROOT / path, destination)
        self.git("init", "-q")
        self.git("add", "--", *runner.SOURCE_FILES)
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "Synthetic report-gate source snapshot")
        self.revision = self.git("rev-parse", "HEAD")
        self.addCleanup(patch.stopall)
        patch.object(runner, "ROOT", self.root).start()
        self.binary = self.root / "invented-binary"
        self.binary.write_bytes(b"invented unit-test executable, never run")
        self.ca = self.root / "invented-ca.der"
        self.ca.write_bytes(b"invented unit-test CA, never used for TLS")
        wire, _, candidate = runner.fixture()
        message = json.loads(candidate)
        receipt = {"status": "STORED_TEST_ONLY", "candidate_sha256": hashlib.sha256(candidate).hexdigest(),
                   "sender": message["sender"], "recipient": message["recipient"], "message_id": message["message_id"],
                   "authority_verified": False, "production_receiver": False}
        self.relay = {"url": "https://127.0.0.1:4443/", "ca_file": str(self.ca)}
        path = {"mode": "relay_only", "ip_bound_sockets": 0,
                "paths": [{"kind": "relay", "selected": True, "address": "relay:" + self.relay["url"],
                           "tx_bytes": 1, "rx_bytes": 1, "stream_rx": 1}]}
        from types import SimpleNamespace
        args = SimpleNamespace(revision=self.revision, local_rehearsal=False, host_label="invented-sender",
                               binary=str(self.binary))
        own, remote = {"role": "sender", "endpoint": "a" * 64}, {"role": "receiver", "endpoint": "b" * 64}
        self.sender = runner.base_report(args, own, remote, self.relay, wire, candidate)
        self.sender.update(state="CONFIRMED_TEST_ONLY", unknown_before_recovery=True,
                           generation=2, receipt=receipt, paths=[path])
        args.host_label = "invented-receiver"
        self.receiver = runner.base_report(args, remote, own, self.relay, wire, candidate)
        self.receiver.update(state="RECEIVER_RETAINED", native_restarted=True, delivery_count=1,
                             receipt=copy.deepcopy(receipt), paths=[copy.deepcopy(path)], requests=[])

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, capture_output=True, text=True,
                              check=True, timeout=10).stdout.strip()

    def compare(self, **kwargs):
        return runner.compare_reports(self.sender, self.receiver, self.revision, **kwargs)

    def test_clean_review_checks_source_checkout_without_attesting_binary_or_host(self):
        result = self.compare()
        self.assertIs(result["checkout_verified"], True)
        self.assertEqual(result["review_checkout_state"], "clean_git_head")
        self.assertIs(result["native_binary_provenance_verified"], False)
        self.assertIs(result["separate_hosts_verified"], False)

    def test_matching_declared_revision_cannot_replace_actual_review_head(self):
        # The source bytes are unchanged, so comparing hashes alone would pass.
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Different reviewing head")
        with self.assertRaisesRegex(ValueError, "exact-revision"):
            self.compare()

    def test_matching_modified_sources_cannot_replace_clean_review(self):
        path = runner.SOURCE_FILES[0]
        (self.root / path).write_bytes((self.root / path).read_bytes() + b"\n")
        for report in (self.sender, self.receiver):
            report["source_sha256"][path] = hashlib.sha256((self.root / path).read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "exact-revision"):
            self.compare()

    def test_staged_source_edit_is_refused(self):
        path = runner.SOURCE_FILES[0]
        (self.root / path).write_bytes(b"changed")
        self.git("add", "--", path)
        with self.assertRaisesRegex(ValueError, "exact-revision"):
            self.compare()

    def test_rehearsal_requires_explicit_comparison_and_stays_unverified(self):
        for report in (self.sender, self.receiver):
            report["checkout_state"] = "local_rehearsal_unverified"
        with self.assertRaisesRegex(ValueError, "explicit rehearsal"):
            self.compare()
        result = self.compare(local_rehearsal=True)
        self.assertIs(result["checkout_verified"], False)
        self.assertEqual(result["review_checkout_state"], "local_rehearsal_unverified")

    def test_explicit_rehearsal_cannot_claim_verified_checkout_from_report_flags(self):
        self.assertIs(self.compare(local_rehearsal=True)["checkout_verified"], False)

    def test_different_relay_trust_roots_are_refused(self):
        self.receiver["relay_ca_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "relay_ca_sha256"):
            self.compare()

    def test_binary_observations_are_recorded_but_not_reproducible_build_assertions(self):
        self.assertEqual(self.sender["native_binary_sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        # Different platforms may have different executables from the same sources.
        self.receiver["native_binary_sha256"] = "0" * 64
        self.assertIs(self.compare()["native_binary_provenance_verified"], False)
        self.receiver["native_binary_sha256"] = "malformed"
        with self.assertRaisesRegex(ValueError, "native_binary_sha256"):
            self.compare()

    def test_boolean_is_not_evidence_of_exactly_one_delivery(self):
        self.receiver["delivery_count"] = True
        with self.assertRaisesRegex(ValueError, "duplicate delivery"):
            self.compare()

    def test_changed_bytes_endpoints_paths_and_authority_are_refused(self):
        mutations = [lambda r: r.update(wire_sha256="0" * 64),
                     lambda r: r.update(peer_endpoint="c" * 64),
                     lambda r: r.update(authority_verified=True),
                     lambda r: r.update(delivery_count=2),
                     lambda r: r["paths"][0].update(ip_bound_sockets=1),
                     lambda r: r["paths"][0]["paths"][0].update(stream_rx=0),
                     lambda r: r["source_sha256"].pop(runner.SOURCE_FILES[0])]
        for mutation in mutations:
            changed = copy.deepcopy(self.receiver)
            mutation(changed)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                runner.compare_reports(self.sender, changed, self.revision)

    def test_old_reports_cannot_silently_gain_new_evidence_claims(self):
        self.receiver["schema"] = "halaqa-two-host-fixture-report/0"
        with self.assertRaisesRegex(ValueError, "role/schema"):
            self.compare()


if __name__ == "__main__":
    unittest.main()
