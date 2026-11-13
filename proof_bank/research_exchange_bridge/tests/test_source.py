"""Source refusal, recovery, and opt-in acceptance with real Lean/mathlib."""
from dataclasses import replace
import base64
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

from research_exchange_bridge import source
from research_exchange_bridge.common import BridgeError, ROOT, canonical, loads, sha
from research_exchange_bridge.store import Store
from research_exchange_bridge.tools.provision_source import install
from adapter_pilot.checker import ControlledChecker, CheckedExport
from adapter_pilot.common import canonical as profile_canonical


class BoundaryTest(unittest.TestCase):
    def test_materialization(self):
        submitted = b"id (Nat.prime_two)  "
        self.assertIn(b"(" + submitted + b")", source.materialize(submitted))
        for data in (b"sorry", b"Nat.prime_two\n#eval 0", b"Nat.prime_twoid", b") Nat.prime_two (",
                     b"import Foo\nNat.prime_two", b"Nat.prime_two /- -/"):
            with self.subTest(data=data), self.assertRaisesRegex(BridgeError, "source_refused"):
                source.materialize(data)
        with self.assertRaisesRegex(BridgeError, "source_resource_limit"):
            source.materialize(b"(" * 65 + b"Nat.prime_two" + b")" * 65)

    def test_prohibited_axiom_report(self):
        for axiom in (b"sorryAx", b"unsafeAxiom"):
            with self.assertRaisesRegex(BridgeError, "source_axioms_prohibited"):
                source.audit_axioms(b"'submitted' depends on axioms: [" + axiom + b"]\n")
        with self.assertRaisesRegex(BridgeError, "source_audit_failed"):
            source.audit_axioms(b"'other' does not depend on any axioms\n")

    def test_process_bounds(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            env = {"PATH": "/usr/bin:/bin"}
            with self.assertRaisesRegex(BridgeError, "source_timeout"):
                source.run_stage(["/usr/bin/sleep", "10"], directory, env, timeout=0.05)
            with self.assertRaisesRegex(BridgeError, "source_resource_limit"):
                source.run_stage([sys.executable, "-c", "print('x' * 2000)"], directory, env, limit=1024)
            with self.assertRaisesRegex(BridgeError, "source_stage_failed"):
                source.run_stage([sys.executable, "-c", "import os,signal; os.kill(os.getpid(),signal.SIGTERM)"],
                                 directory, env)
            self.assertEqual(source.run_stage(["/usr/bin/printf", "recovered"], directory, env), b"recovered")

    def test_export_budget_is_bound_to_the_stored_policy(self):
        environment = "1" * 64
        term = b"Nat.prime_two"
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store(root / "bridge.sqlite", b"x" * 32)
            store.initialize()
            for policy, wall_seconds in ((source.POLICY, 60), (source.EXTENDED_POLICY, 180)):
                with self.subTest(wall_seconds=wall_seconds):
                    profile = source.profile_for(environment, policy)
                    library = {"id": f"source-{wall_seconds}", "engine": "lean",
                               "revision": source.REVISION, "generation": 1,
                               "snapshot_sha256": profile["source_sha256"],
                               "environment_sha256": environment,
                               "policy_sha256": sha(profile_canonical(policy))}
                    store.provision_library(library, profile)
                    with store.connection() as conn:
                        stored = loads(store._library(conn, library["id"])["profile_json"])
                    checker = Mock(spec=ControlledChecker)
                    checker.paths = {"lean": "/unused/lean", "leanexport": "/unused/leanexport"}
                    binding = {"artifact_sha256": sha(term), "target": source.TARGET,
                               "environment_sha256": environment, "source_revision": source.REVISION}
                    with patch.object(checker, "environment", return_value={}), \
                         patch.object(source, "environment_identity", return_value=environment), \
                         patch.object(source, "run_stage", side_effect=[
                             b"", b"'submitted' does not depend on any axioms\n",
                             BridgeError("source_timeout"),
                         ]) as stage:
                        with self.assertRaisesRegex(BridgeError, "source_timeout"):
                            source.check_source(checker, root, stored, term, binding,
                                                sha(profile_canonical(stored)))
                    self.assertEqual(stage.call_args.kwargs["timeout"], wall_seconds)
            invalid = {**source.EXTENDED_POLICY, "export_wall_seconds": 181}
            with self.assertRaisesRegex(BridgeError, "profile_identity_mismatch"):
                source.profile_for(environment, invalid)

    def test_dependency_fingerprint(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "Mathlib/Data/Nat/Prime/Defs.olean"
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b"original")
            expected = source.dependency_identity(root)
            artifact.write_bytes(b"substituted")
            self.assertNotEqual(expected, source.dependency_identity(root))
            (root / "shadow.olean").symlink_to(artifact)
            with self.assertRaisesRegex(BridgeError, "source_environment_mismatch"):
                source.dependency_identity(root)


@unittest.skipUnless(os.environ.get("EXCHANGE_SOURCE_IMPORTS") and os.environ.get("EXCHANGE_LEAN_ROOT"),
                     "set EXCHANGE_SOURCE_IMPORTS and EXCHANGE_LEAN_ROOT for real acceptance")
class DurableSourceTest(unittest.TestCase):
    def test_guarded_replay_and_recovery(self):
        lean = Path(os.environ["EXCHANGE_LEAN_ROOT"])
        imports = Path(os.environ["EXCHANGE_SOURCE_IMPORTS"])
        checker = ControlledChecker(lean)
        with TemporaryDirectory() as temporary:
            store = Store(Path(temporary) / "test.sqlite", b"x" * 32)
            store.initialize()
            library = install(store, checker, imports)
            token = "source-acceptance-grant-01234567890123456789"
            store.provision_grant(token, "source-researcher", [library["id"]],
                                  ["proof:submit", "verification:request"], 4_000_000_000)
            term = b"id (Nat.prime_two)"
            args = {"library": library["id"], "revision": library["revision"],
                    "snapshot_sha256": library["snapshot_sha256"], "generation": 1,
                    "target": source.TARGET, "artifact": term.decode(), "artifact_sha256": sha(term),
                    "idempotency_key": "source-submit"}
            for changes in ({"target": "other"}, {"artifact": "Nat.prime_two"}, {"revision": "0" * 40}):
                with self.assertRaisesRegex(BridgeError, "invalid_or_stale_binding"):
                    store.call(token, "proof_submit", {**args, **changes})
            submission = store.call(token, "proof_submit", args)["payload"]
            self.assertEqual(submission["acceptance_scope"], source.SCOPE)
            job = store.call(token, "verification_request",
                             {"submission_id": submission["id"], "idempotency_key": "source-job"})["payload"]["id"]
            self.assertEqual(store.pending(include_source=False), [])
            self.assertEqual(store.pending(), [job])
            with TemporaryDirectory() as altered:
                dependency = Path(altered) / "Mathlib/Data/Nat/Prime/Defs.olean"
                dependency.parent.mkdir(parents=True)
                dependency.write_bytes(b"altered dependency")
                store.execute_one(job, lean, source_root=altered)
            refused = store.inspect(job)
            self.assertEqual(refused["receipt"]["payload"]["details"]["reason"], "source_environment_mismatch")
            self.assertEqual((refused["version"], refused["effects"]), (0, []))

            # Simulate the failure of each stage at the durable boundary without
            # depending on host scheduling or a compiler resource regression.
            for reason in ("source_timeout", "source_resource_limit", "source_stage_failed",
                           "source_axioms_prohibited"):
                store.retry(job)
                with patch.object(source, "run_stage", side_effect=BridgeError(reason)):
                    store.execute_one(job, lean, source_root=imports)
                refused = store.inspect(job)
                self.assertEqual(refused["receipt"]["payload"]["details"]["reason"], reason)
                self.assertEqual((refused["version"], refused["effects"]), (0, []))

            store.retry(job)
            prepared = store.prepare(job)
            profile, binding = loads(prepared.profile_json), loads(prepared.binding_json)
            with self.assertRaisesRegex(BridgeError, "stored_identity_mismatch"):
                source.check_source(checker, imports, profile, b"Nat.prime_two", binding, prepared.profile_sha256)
            with self.assertRaisesRegex(BridgeError, "checker_inconclusive"):
                store.commit(prepared, CheckedExport(prepared.profile_sha256, sha(term), {}))
            checked = source.check_source(checker, imports, profile, term, binding, prepared.profile_sha256)
            for changes in ({"source_sha256": "0" * 64}, {"target": "other"}, {"axioms": ["sorryAx"]},
                            {"closure_sha256": "0" * 64}, {"environment_sha256": "0" * 64},
                            {"statement_sha256": "0" * 64}, {"library_revision": "0" * 40},
                            {"policy_sha256": "0" * 64}):
                with self.assertRaisesRegex(BridgeError, "checker_inconclusive"):
                    store.commit(prepared, replace(checked, receipt={**checked.receipt, **changes}))
            config = Path(temporary) / "bridge.json"
            config.write_bytes(canonical({"database": str(store.path), "lean_root": str(lean),
                                         "receipt_key_base64": base64.b64encode(store.key).decode()}))
            command = [sys.executable, str(ROOT / "worker.py"), "--config", str(config),
                       "--job-id", job, "--source-imports", str(imports)]
            # The private scratch directory appears only after environment validation.
            scratch = Path(temporary) / "scratch"
            scratch.mkdir()
            with subprocess.Popen(command, env={**os.environ, "TMPDIR": str(scratch)},
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as worker:
                try:
                    deadline = time.monotonic() + 120
                    while not list(scratch.glob("exchange-source-*/Submission.lean")):
                        self.assertIsNone(worker.poll(), "worker exited before materialization")
                        self.assertLess(time.monotonic(), deadline, "materialization did not start")
                        time.sleep(0.01)
                    worker.send_signal(signal.SIGINT)
                    self.assertNotEqual(worker.wait(timeout=20), 0)
                finally:
                    if worker.poll() is None:
                        worker.kill()
            interrupted = store.inspect(job)
            self.assertEqual((interrupted["version"], interrupted["effects"]), (0, []))
            self.assertEqual(store.pending(), [job])
            self.assertEqual(list(scratch.iterdir()), [])
            result = subprocess.run(command, capture_output=True, text=True, timeout=480, check=True)
            self.assertEqual(loads(result.stdout)["status"], "accepted", store.inspect(job)["receipt"])
            receipt = store.inspect(job)["receipt"]
            self.assertEqual(store.commit(prepared, checked), receipt)
            self.assertTrue(receipt["payload"]["mathematical_acceptance"])
            self.assertFalse(receipt["payload"]["credit_issuance"])
            self.assertEqual(receipt["payload"]["acceptance_scope"], source.SCOPE)
            self.assertEqual(len(store.inspect(job)["effects"]), 1)
            evidence_path = os.environ.get("EXCHANGE_SOURCE_EVIDENCE")
            if evidence_path:
                payload = receipt["payload"]
                Path(evidence_path).write_bytes(canonical({
                    "binding": payload["binding"], "controlled_check": payload["details"]["controlled_check"],
                    "mathematical_acceptance": payload["mathematical_acceptance"],
                    "credit_issuance": payload["credit_issuance"], "state_version": payload["state_version"],
                }) + b"\n")


if __name__ == "__main__":
    unittest.main()
