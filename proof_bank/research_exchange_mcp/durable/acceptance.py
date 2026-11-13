"""End-to-end evidence for the disposable durable MCP profile."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from runtime import CORE_ROOT, ROOT, Store, canonical, digest, profile_binding
from adapter_pilot.checker import ControlledChecker
from adapter_pilot.common import PilotError
from adapter_pilot.prepare_fixture import prepare_fixture


class Session:
    def __init__(self, process, key):
        self.process, self.key, self.next_id = process, key, 0
        self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                "clientInfo": {"name": "durable-acceptance", "version": "1"}})
        self.send({"method": "notifications/initialized"})

    def send(self, message):
        frame = json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False).encode("utf-8")
        self.process.stdin.write(frame + b"\n")
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.next_id += 1
        self.send({"method": method, "params": params, "id": self.next_id})
        response = json.loads(self.process.stdout.readline())
        if response.get("id") != self.next_id or response.get("jsonrpc") != "2.0":
            raise AssertionError("mismatched JSON-RPC response")
        return response

    def call(self, tool, arguments, error=None):
        result = self.rpc("tools/call", {"name": tool, "arguments": arguments})["result"]
        if error is not None:
            assert result["isError"] and result["content"][0]["text"] == error, result
            return
        assert not result["isError"], result
        value = result["structuredContent"]
        if "payload" in value:
            payload = value["payload"]
            signed = b"research-exchange/receipt/v1\n" + canonical(payload)
            assert value["sha256"] == digest(signed), value
            assert value["server_mac"] == hmac.new(self.key, signed, hashlib.sha256).hexdigest()
            assert payload["mathematical_acceptance"] is False
            assert payload["credit_issuance"] is False
        return value


class RoundTrip(unittest.TestCase):
    def setUp(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.token, self.key = secrets.token_urlsafe(32), secrets.token_bytes(32)
        self.store = Store(directory / "pilot.db")
        self.store.provision(self.profile, self.token, int(time.time()) + 3600)
        self.config = directory / "operator.json"
        self.config.write_bytes(canonical({"durable_database": str(self.store.path),
                                           "receipt_key_base64": base64.b64encode(self.key).decode()}))
        self.checker = ControlledChecker(self.lean, CORE_ROOT)

    @contextmanager
    def mcp(self):
        env = {**os.environ, "RESEARCH_EXCHANGE_CONFIG": str(self.config),
               "RESEARCH_EXCHANGE_TOKEN": self.token}
        with subprocess.Popen(["elixir", str(ROOT / "bin/stdio.exs")], env=env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
            try:
                yield Session(process, self.key)
            finally:
                process.stdin.close()
                if process.wait(timeout=15) != 0:
                    raise AssertionError("MCP launcher failed")

    def submission(self, mcp, label):
        lib, = mcp.call("library_discover", {})["libraries"]
        artifact = (self.output / f"{label}.export").read_bytes()
        return {"idempotency_key": "submit", "library": lib["id"], "revision": lib["revision"],
                "snapshot_sha256": lib["snapshot_sha256"], "generation": lib["generation"],
                "target": lib["target"], "artifact": artifact.decode("utf-8"),
                "artifact_sha256": digest(artifact)}

    def queue(self, label="expected"):
        with self.mcp() as mcp:
            submit = self.submission(mcp, label)
            admitted = mcp.call("proof_submit", submit)
            job_args = {"submission_id": admitted["payload"]["id"], "idempotency_key": "verify"}
            queued = mcp.call("verification_request", job_args)
        return submit, admitted, job_args, queued

    def stored_job(self):
        with self.store.transaction(read_only=True) as db:
            return db.execute("SELECT * FROM job").fetchone()

    def test_success_and_restart(self):
        submit, admitted, job_args, queued = self.queue()
        binding = admitted["payload"]["binding"]
        self.assertEqual(queued["payload"]["binding"], {**binding, "submission_id": job_args["submission_id"]})
        self.assertEqual(binding["artifact_sha256"], submit["artifact_sha256"])
        self.assertEqual(binding["target"], submit["target"])
        self.assertEqual(binding["snapshot_sha256"], submit["snapshot_sha256"])
        self.assertEqual(binding["environment_sha256"], self.profile["toolchain_lock_sha256"])
        self.assertEqual(int(binding["policy_sha256"], 16), profile_binding(self.profile)["policy"])
        self.assertEqual(binding["authority_epoch"], 1)
        result = json.loads(subprocess.check_output(
            [sys.executable, "-B", str(ROOT / "durable/runtime.py"), "--db",
             str(self.store.path), "replay", "--lean-root", str(self.lean)], timeout=90
        ))
        self.assertEqual(result["status"], "dual_checker_passed")
        evidence = self.stored_job()["evidence"]
        self.assertEqual(result["details"]["evidence_sha256"], digest(evidence))
        self.assertEqual([x["checker"] for x in json.loads(evidence)["checkers"]],
                         ["leanchecker", "lean4lean"])
        with self.mcp() as mcp:
            self.assertEqual(mcp.call("proof_submit", submit), admitted)
            self.assertEqual(mcp.call("verification_request", job_args), queued)
            mcp.call("proof_submit", {**submit, "target": "different"}, "idempotency_conflict")
            self.assertEqual(mcp.call("receipt_get", {"id": result["id"]})["payload"], result)
        (self.output / "dual-checker-receipt.json").write_bytes(evidence + b"\n")
        (self.output / "wire-disposition.json").write_bytes(canonical(result) + b"\n")
        self.check_lean_projection(submit, binding)

    def check_lean_projection(self, submit, binding):
        with self.store.transaction(read_only=True) as db:
            persisted = db.execute("SELECT binding, artifact FROM admission").fetchone()
        self.assertEqual(json.loads(persisted["binding"]), binding)
        self.assertEqual(persisted["artifact"], submit["artifact"].encode("utf-8"))
        target = int(digest(submit["target"].encode("ascii")), 16)
        projection = self.output / "AdmissionProjection.lean"
        projection.write_text((ROOT / "durable/formal/Admission.lean").read_text() + f"""
open ResearchExchange ResearchExchange.MCPDurable
def approved : Binding :=
  ⟨{target}, {int(binding["snapshot_sha256"], 16)},
    {int(binding["environment_sha256"], 16)}, {int(binding["policy_sha256"], 16)}⟩
def cfg : Reward.Config := ⟨approved, 0, 1, 2⟩
def leased := Reward.lease cfg (Reward.tick (Reward.initial cfg 0 0 0)
  {binding["submitted_at"]}) 1 {binding["lease_expires"]}
def request : Admission :=
  ⟨{binding["worker"]}, {binding["generation"]}, approved,
    {int(digest(persisted["artifact"]), 16)}, {binding["authority_epoch"]}⟩
def row : Row := ⟨request, {binding["submitted_at"]}, {binding["lease_expires"]}⟩
def committed := admit cfg leased ⟨1, 1, true⟩ request
example : committed.1 = some row := by decide
example : committed.2.phase = .submitted ∧ committed.2.candidate = some row.candidate ∧
    committed.2.payouts = 0 ∧ committed.2.escrow = 0 := by decide
#print axioms ResearchExchange.MCPDurable.committed_admission
#print axioms ResearchExchange.MCPDurable.refusal_stutters
#print axioms ResearchExchange.MCPDurable.inconclusive_stutters
#print axioms ResearchExchange.MCPDurable.stale_epoch_stutters
#print axioms ResearchExchange.MCPDurable.terminal_immutable
""")
        completed = subprocess.run(
            [str(self.lean / "bin/lean"), "-DwarningAsError=true", str(projection)],
            env=self.checker.environment(CORE_ROOT / "formal/lean/.lake/build/lib/lean"),
            capture_output=True, timeout=60,
        )
        output = completed.stdout + completed.stderr
        (self.output / "lean-projection.log").write_bytes(output)
        self.assertEqual(completed.returncode, 0, output.decode(errors="replace"))
        self.assertNotIn(b"sorryAx", output)

    def test_wrong_target_and_substituted_source(self):
        with self.mcp() as mcp:
            submit = self.submission(mcp, "expected")
            for changes in ({"target": "wrong"}, {"revision": "0" * 40},
                            {"snapshot_sha256": "0" * 64}, {"artifact": "different bytes"}):
                error = "invalid_artifact" if "artifact" in changes else "invalid_or_stale_binding"
                mcp.call("proof_submit", {**submit, **changes}, error)
            with self.store.transaction(read_only=True) as db:
                self.assertIsNone(db.execute("SELECT 1 FROM admission").fetchone())
                self.assertIsNone(db.execute("SELECT 1 FROM replay").fetchone())
        self.queue("alternate")
        self.assertEqual(self.store.replay(self.checker)["status"], "profile_rejected")

    def test_substituted_stored_artifact(self):
        self.queue()
        with self.store.transaction() as db:
            db.execute("UPDATE admission SET artifact=?", (b"substituted",))
        with patch.object(self.checker, "check") as check:
            with self.assertRaisesRegex(PilotError, "stored_identity_mismatch"):
                self.store.replay(self.checker)
            check.assert_not_called()
        self.assertIsNone(self.stored_job()["terminal"])

    def test_utf8_artifact_and_null_argument(self):
        artifact = "-- αβ é 漢字 🧪\n"
        encoded = artifact.encode("utf-8")
        with self.mcp() as mcp:
            submit = self.submission(mcp, "expected")
            mcp.call("proof_submit", {**submit, "artifact": None,
                     "artifact_sha256": digest(b"nil")}, "invalid_artifact")
            admitted = mcp.call("proof_submit", {**submit, "artifact": artifact,
                                "artifact_sha256": digest(encoded)})
            self.assertEqual(admitted["payload"]["binding"]["artifact_sha256"], digest(encoded))
        with self.store.transaction(read_only=True) as db:
            self.assertEqual(db.execute("SELECT artifact FROM admission").fetchone()[0], encoded)

    def test_revoked_in_flight_grant(self):
        _, _, _, queued = self.queue()
        with self.mcp() as mcp:
            # Revocation is injected after real replay, before entering the CAS.
            real_check = self.checker.check
            def checked_then_revoked(*args):
                result = real_check(*args)
                self.store.revoke()
                return result

            with patch.object(self.checker, "check", side_effect=checked_then_revoked):
                with self.assertRaisesRegex(PilotError, "stale_authority"):
                    self.store.replay(self.checker)
            self.assertEqual(mcp.rpc("tools/call", {"name": "receipt_get",
                             "arguments": {"id": queued["payload"]["id"]}})["error"]["code"], -32001)
        self.assertIsNone(self.stored_job()["terminal"])

    def test_competing_replays(self):
        self.queue()
        gate = threading.Barrier(2, timeout=60)
        real_check = self.checker.check
        def simultaneous(*args):
            result = real_check(*args)
            gate.wait()
            return result
        with patch.object(self.checker, "check", side_effect=simultaneous):
            with ThreadPoolExecutor(2) as workers:
                attempts = [workers.submit(self.store.replay, self.checker) for _ in range(2)]
                first, second = [attempt.result(timeout=90) for attempt in attempts]
        self.assertEqual(first, second)
        self.assertEqual(first, json.loads(self.stored_job()["terminal"]))

    def test_inconclusive_and_retry(self):
        self.queue()
        with patch("adapter_pilot.checker.subprocess.run",
                   side_effect=subprocess.TimeoutExpired("leanchecker", 30)):
            with self.assertRaisesRegex(PilotError, "checker_unavailable"):
                self.store.replay(self.checker)
        self.assertIsNone(self.stored_job()["terminal"])
        self.assertIsNone(self.stored_job()["evidence"])
        self.assertEqual(self.store.replay(self.checker)["status"], "dual_checker_passed")

    def test_process_crash_before_and_after_commit(self):
        _, _, _, queued = self.queue()
        code = """
import os, sys
from runtime import CORE_ROOT, ControlledChecker, Store
Store(sys.argv[1]).replay(ControlledChecker(sys.argv[2], CORE_ROOT),
    **{sys.argv[3]: lambda: os._exit(73)})
"""
        for point in ("before_commit", "after_commit"):
            result = subprocess.run([sys.executable, "-B", "-c", code, str(self.store.path),
                                     str(self.lean), point], cwd=ROOT / "durable", timeout=90)
            self.assertEqual(result.returncode, 73)
            with self.mcp() as mcp:
                observed = mcp.call("receipt_get", {"id": queued["payload"]["id"]})
            if point == "before_commit":
                self.assertEqual(observed, queued)
                self.assertIsNone(self.stored_job()["evidence"])
            else:
                self.assertEqual(observed["payload"], self.store.replay(self.checker))
                self.assertEqual(observed["payload"]["status"], "dual_checker_passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    RoundTrip.lean = args.lean_root.resolve()
    RoundTrip.output = args.output.resolve()
    RoundTrip.profile = prepare_fixture(CORE_ROOT, RoundTrip.lean, RoundTrip.output)["profile"]
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RoundTrip)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
