"""Source refusals and actual MCP/operator acceptance with pinned Lean/mathlib."""
from dataclasses import replace
import base64
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import time
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from research_exchange_bridge import source
from research_exchange_bridge.common import BridgeError, ROOT, canonical, loads, sha
from research_exchange_bridge.store import Store
from research_exchange_bridge.tests.test_acceptance import MCPClient
from research_exchange_bridge.tools.provision_source import install
from adapter_pilot.checker import ControlledChecker, CheckedExport, RejectedExport


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
    def mcp_instance(self):
        """Private operator provision; all research-agent actions use stdio below."""
        self.lean = Path(os.environ["EXCHANGE_LEAN_ROOT"]).resolve(strict=True)
        self.imports = Path(os.environ["EXCHANGE_SOURCE_IMPORTS"]).resolve(strict=True)
        executable = (os.environ.get("EXCHANGE_SOURCE_ELIXIR") or
                      os.environ.get("RESEARCH_EXCHANGE_BRIDGE_ELIXIR") or shutil.which("elixir"))
        self.assertIsNotNone(executable, "actual source MCP acceptance requires Elixir")
        self.elixir = Path(executable).resolve(strict=True)
        temporary = TemporaryDirectory(prefix="source-mcp-acceptance-")
        self.addCleanup(temporary.cleanup)
        self.instance = Path(temporary.name)
        self.key = secrets.token_bytes(32)
        self.token = secrets.token_urlsafe(40)
        self.checker = ControlledChecker(self.lean)
        self.store = Store(self.instance / "bridge.sqlite", self.key)
        self.store.initialize()
        self.library = install(self.store, self.checker, self.imports)
        self.store.provision_grant(self.token, "source-researcher", [self.library["id"]],
                                   ["library:read", "proof:submit", "verification:request"], 4_000_000_000)
        self.config_path = self.instance / "bridge.json"
        self.outer_path = self.instance / "mcp.json"
        self.encoded_key = base64.b64encode(self.key).decode()
        config = {"database": str(self.store.path), "lean_root": str(self.lean),
                  "receipt_key_base64": self.encoded_key, "worker_enabled": True}
        outer = {"backend": "durable", "bridge_config": str(self.config_path),
                 "python_executable": str(Path(sys.executable).resolve(strict=True))}
        for path, value in ((self.config_path, config), (self.outer_path, outer)):
            path.write_bytes(canonical(value) + b"\n")
            path.chmod(0o600)
        # Spaces are intentionally preserved through the real
        # transport, immutable storage, materialization, and signed receipt.
        self.term = b"  id  (Nat.prime_two)  "
        self.clients, self.jobs, self.events = [], [], []
        self.addCleanup(self.finish_mcp_case)

    def finish_mcp_case(self):
        for client in self.clients:
            client.close()
        evidence = {
            "schema": "research-exchange/durable-runtime-case/v1",
            "test": self._testMethodName, "scope": source.SCOPE,
            "submitted_source": self.term.decode("ascii"), "events": self.events,
            "database_observations": [
                {"job_id": job, "observation": self.store.inspect(job)} for job in self.jobs],
            "clients": [{"name": client.name, "transcript": client.transcript,
                         "returncode": client.process.returncode, "stderr": client.stderr}
                        for client in self.clients],
        }
        encoded = canonical(evidence).decode().replace(str(self.instance), "<private-instance>")
        for secret in (self.token, self.encoded_key):
            self.assertNotIn(secret, encoded, "private credentials cannot enter source acceptance evidence")
        output = os.environ.get("EXCHANGE_SOURCE_ACCEPTANCE_OUTPUT")
        if output:
            (Path(output) / f"{self._testMethodName}.json").write_text(encoded + "\n")

    def client(self):
        client = MCPClient(self.elixir, self.outer_path, self.token, f"source-client-{len(self.clients) + 1}")
        self.clients.append(client)
        client.initialize()
        return client

    def success(self, response):
        self.assertNotIn("error", response)
        result = response["result"]
        self.assertIs(result["isError"], False)
        value = result["structuredContent"]
        # This text was encoded by the actual Elixir frontend, independently
        # of the Python canonical encoder used to sign the receipt payload.
        self.assertEqual(result["content"], [{"type": "text", "text": canonical(value).decode()}])
        return value

    def refusal(self, response, code):
        self.assertNotIn("error", response)
        self.assertEqual(response["result"], {
            "isError": True, "content": [{"type": "text", "text": code}],
        })

    def assert_receipt(self, receipt, *, accepted=False):
        data = b"research-exchange/receipt/v1\n" + canonical(receipt["payload"])
        self.assertEqual(receipt["sha256"], hashlib.sha256(data).hexdigest())
        self.assertTrue(hmac.compare_digest(receipt["server_mac"], hmac.new(self.key, data, "sha256").hexdigest()))
        self.assertIs(receipt["payload"]["mathematical_acceptance"], accepted)
        self.assertIs(receipt["payload"]["credit_issuance"], False)
        self.assertEqual(receipt["payload"]["acceptance_scope"], source.SCOPE)

    def arguments(self):
        return {"library": self.library["id"], "revision": self.library["revision"],
                "snapshot_sha256": self.library["snapshot_sha256"], "generation": self.library["generation"],
                "target": source.TARGET, "artifact": self.term.decode("ascii"),
                "artifact_sha256": sha(self.term), "idempotency_key": "source-mcp-submit"}

    def admit(self, client):
        submitted = self.success(client.tool("proof_submit", self.arguments()))
        self.assert_receipt(submitted)
        self.assertEqual(submitted["payload"]["status"], "submitted")
        started = time.monotonic()
        queued = self.success(client.tool("verification_request", {
            "submission_id": submitted["payload"]["id"], "idempotency_key": "source-mcp-verify"}))
        self.assertLess(time.monotonic() - started, 4, "source admission must not wait for compilation")
        self.assert_receipt(queued)
        self.assertEqual(queued["payload"]["status"], "queued")
        self.assertEqual(queued["payload"]["details"]["reservation"], "durable-source-slot")
        job = queued["payload"]["id"]
        self.jobs.append(job)
        self.assertEqual(self.store.pending(include_source=False), [])
        self.assertEqual(self.store.pending(), [job])
        return submitted, queued, job

    def test_mcp_source_roundtrip_binds_real_replay(self):
        self.mcp_instance()
        client = self.client()
        tools = client.request("tools/list")["result"]["tools"]
        self.assertEqual({tool["name"] for tool in tools},
                         {"library_discover", "proof_submit", "verification_request", "receipt_get"})
        discovery = self.success(client.tool("library_discover", {}))
        self.assertEqual(discovery["libraries"], [self.library])
        self.assertEqual(discovery["execution"], "durable-operator-provisioned-profiles")
        self.assertEqual(self.library["revision"], "56a005855ea17e0b0958f73ec801ae140b0a1679")
        self.assertFalse(discovery["benefits"]["issuance_enabled"])
        submitted, queued, job = self.admit(client)
        self.assertEqual(self.success(client.tool("receipt_get", {"id": job})), queued)
        self.assertEqual(self.store.prepare(job).artifact, self.term)
        # A live frontend's ordinary background worker cannot execute source.
        # Close it cleanly, then exercise the explicitly authorized CLI worker.
        self.assertEqual(client.close(), 0)
        command = [sys.executable, str(ROOT / "worker.py"), "--config", str(self.config_path),
                   "--job-id", job, "--source-imports", str(self.imports)]
        started = time.monotonic_ns()
        result = subprocess.run(command, capture_output=True, text=True, timeout=360, check=False)
        self.events.append({"operator_worker": "explicit-source-imports", "returncode": result.returncode,
                            "argv": command, "duration_ns": time.monotonic_ns() - started,
                            "stdout": result.stdout, "stderr": result.stderr})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(loads(result.stdout)["status"], "accepted", self.store.inspect(job)["receipt"])
        restarted = self.client()
        accepted = self.success(restarted.tool("receipt_get", {"id": job}))
        self.assert_receipt(accepted, accepted=True)
        self.assertEqual(accepted["payload"]["status"], "accepted")
        self.assertEqual(accepted["payload"]["binding"], queued["payload"]["binding"])
        self.assertEqual({key: value for key, value in queued["payload"]["binding"].items()
                          if key != "submission_id"}, submitted["payload"]["binding"])
        binding = accepted["payload"]["binding"]
        checked = accepted["payload"]["details"]["controlled_check"]
        self.assertEqual(checked["schema"], source.SCHEMA)
        self.assertEqual(checked["scope"], source.SCOPE)
        self.assertEqual(checked["status"], "passed")
        self.assertEqual(checked["source_sha256"], sha(self.term))
        self.assertEqual(binding["artifact_sha256"], sha(self.term))
        self.assertEqual(checked["materialized_sha256"], sha(source.materialize(self.term)))
        self.assertEqual(checked["statement_sha256"], sha(b"Nat.Prime 2"))
        self.assertEqual(checked["target"], "submitted")
        self.assertEqual(checked["library_revision"], binding["source_revision"])
        self.assertEqual(checked["library_revision"], self.library["revision"])
        self.assertEqual(binding["source_snapshot_sha256"], self.library["snapshot_sha256"])
        for name in ("environment_sha256", "policy_sha256"):
            self.assertEqual(checked[name], binding[name])
            self.assertEqual(checked[name], self.library[name])
        self.assertRegex(checked["closure_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(checked["checkers"], [
            {"checker": name, "closure_sha256": checked["closure_sha256"], "status": "passed"}
            for name in ("leanchecker", "lean4lean")])
        self.assertTrue(set(checked["axioms"]) <= {"Classical.choice", "Quot.sound", "propext"})
        self.assertEqual(accepted["payload"]["details"]["credits_issued"], 0)
        self.assertEqual(self.success(restarted.tool("proof_submit", self.arguments())), submitted)
        self.assertEqual(self.success(restarted.tool("verification_request", {
            "submission_id": submitted["payload"]["id"], "idempotency_key": "source-mcp-verify"})), queued)
        self.assertEqual(self.success(restarted.tool("receipt_get", {"id": job})), accepted)
        observed = self.store.inspect(job)
        self.assertEqual((observed["version"], observed["terminal"], observed["outbox"]), (1, True, "complete"))
        self.assertEqual(observed["state"]["phase"], "accepted")
        self.assertEqual(len(observed["effects"]), 1)
        effect = observed["effects"][0]
        self.assertEqual((effect["kind"], effect["before_version"], effect["after_version"]), ("accepted", 0, 1))
        self.assertEqual(loads(effect["receipt_json"]), accepted)
        self.assertEqual(observed["sqlite"], {"journal_mode": "wal", "synchronous": 2, "foreign_keys": 1})

        # Verify real Python-issued source receipts with the actual Elixir
        # verifier; every substituted proof identity must invalidate its MAC.
        fields = ("source_sha256", "materialized_sha256", "statement_sha256", "environment_sha256",
                  "closure_sha256", "library_revision", "policy_sha256")
        mutations = []
        for field in fields:
            changed = loads(canonical(accepted))
            changed["payload"]["details"]["controlled_check"][field] = "0" * len(checked[field])
            # An attacker can recompute the public digest but not the MAC.
            changed["sha256"] = sha(b"research-exchange/receipt/v1\n" + canonical(changed["payload"]))
            mutations.append(changed)
        code = '''
        alias ResearchExchange.Evidence
        :ok = :io.setopts(:standard_io, encoding: :unicode)
        {input, _, ""} = :json.decode(IO.read(:stdio, :eof), :ok, %{null: nil})
        key = System.fetch_env!("RESEARCH_EXCHANGE_CANONICAL_KEY") |> Base.decode64!()
        IO.write(:stdio, Evidence.canonical(Enum.map(input, &Evidence.verify_receipt?(&1, key))))
        '''
        result = subprocess.run(
            [str(self.elixir), "-r", str(ROOT.parent / "research_exchange_mcp/lib/research_exchange/evidence.ex"),
             "-e", code], input=canonical([submitted, queued, accepted] + mutations), capture_output=True,
            env={**os.environ, "RESEARCH_EXCHANGE_CANONICAL_KEY": self.encoded_key}, timeout=20, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        verified = loads(result.stdout)
        self.assertEqual(verified, [True, True, True] + [False] * len(fields))
        self.events.append({"actual_elixir_receipt_verifier": verified,
                            "substituted_controlled_check_fields": list(fields),
                            "substituted_payloads_rehashed": True, "exit_code": result.returncode})

    def test_mcp_source_binding_and_profile_refusals(self):
        self.mcp_instance()
        client = self.client()
        discovery = self.success(client.tool("library_discover", {}))
        self.assertEqual(discovery["libraries"], [self.library])
        self.assertEqual(discovery["execution"], "durable-operator-provisioned-profiles")
        for changes in ({"artifact": "Nat.prime_two"}, {"artifact_sha256": "0" * 64},
                        {"revision": "0" * 40}, {"snapshot_sha256": "0" * 64}, {"generation": 2},
                        {"target": "ResearchExchange.Adapter.expected_fixture"}):
            with self.subTest(changes=changes):
                self.refusal(client.tool("proof_submit", {**self.arguments(), **changes}), "invalid_or_stale_binding")
        for term in (b"sorry", b"Nat.prime_two\n#eval 0", b"import Mathlib\nNat.prime_two", b"#DEF 0 0"):
            with self.subTest(term=term):
                self.refusal(client.tool("proof_submit", {**self.arguments(), "artifact": term.decode(),
                                                          "artifact_sha256": sha(term)}), "invalid_or_stale_binding")
        for field, value in (("profile", "exact-reviewed-export-only"), ("acceptance_scope", source.SCOPE),
                             ("source_imports", str(self.imports)), ("checked", True)):
            with self.subTest(field=field):
                self.refusal(client.tool("proof_submit", {**self.arguments(), field: value}), "invalid_arguments")
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM bridge_submissions").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM bridge_effects").fetchone()[0], 0)
        _, queued, job = self.admit(client)
        substituted = b"Nat.prime_two"
        self.refusal(client.tool("proof_submit", {**self.arguments(), "artifact": substituted.decode(),
                                                  "artifact_sha256": sha(substituted)}), "idempotency_conflict")
        prepared = self.store.prepare(job)
        with self.assertRaisesRegex(BridgeError, "stored_identity_mismatch"):
            source.check_source(self.checker, self.imports, loads(prepared.profile_json), substituted,
                                loads(prepared.binding_json), prepared.profile_sha256)
        # Exercise the actual durable type gate after MCP admission. An export
        # verifier's result must never settle a source-profile job in either direction.
        for wrong_type in (CheckedExport(prepared.profile_sha256, sha(self.term), {}),
                           RejectedExport(prepared.profile_sha256, sha(self.term))):
            with self.subTest(result_type=type(wrong_type).__name__), self.assertRaisesRegex(BridgeError, "checker_inconclusive"):
                self.store.commit(prepared, wrong_type)
            self.events.append({"refused_checker_result_type": type(wrong_type).__name__, "reason": "checker_inconclusive"})
        observed = self.store.inspect(job)
        self.assertEqual((observed["version"], observed["terminal"], observed["effects"], observed["outbox"]),
                         (0, False, [], "pending"))
        self.assertEqual(self.success(client.tool("receipt_get", {"id": job})), queued)

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
            for changes in ({"source_sha256": "0" * 64}, {"materialized_sha256": "0" * 64},
                            {"target": "other"}, {"axioms": ["sorryAx"]},
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
            result = subprocess.run(command, capture_output=True, text=True, timeout=360, check=True)
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
                    "schema": "research-exchange/source-interruption-recovery/v1",
                    "test": self._testMethodName, "submitted_source": term.decode(),
                    "database_observation": store.inspect(job),
                    "binding": payload["binding"], "controlled_check": payload["details"]["controlled_check"],
                    "mathematical_acceptance": payload["mathematical_acceptance"],
                    "credit_issuance": payload["credit_issuance"], "state_version": payload["state_version"],
                }) + b"\n")


if __name__ == "__main__":
    unittest.main()
