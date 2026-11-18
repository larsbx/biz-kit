"""Actual Elixir stdio, SQLite, and pinned dual-checker acceptance.

Run through tools/run_acceptance.py. Missing tools or fixtures are failures, never
skips. Operator fixtures, bearer tokens, keys and databases live only in private
temporary directories. Published observations contain receipts and sanitized
protocol transcripts, including concrete committed refinement inputs.
"""
from __future__ import annotations

from dataclasses import replace
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import selectors
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

from research_exchange_bridge.common import (
    BridgeError, CORE, ROOT, canonical, loads, receipt_key, sha,
)
from research_exchange_bridge.provision import provision
from research_exchange_bridge.store import Store
from adapter_pilot.checker import ControlledChecker


def wait_for(predicate, *, timeout=30, message="condition did not become true"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.025)
    raise AssertionError(message)


def stop_process(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)


def protocol_summary(value):
    if isinstance(value, dict):
        return {
            key: ({"summary_only": True, "utf8_bytes": len(child.encode("utf-8")),
                   "sha256": sha(child.encode("utf-8"))}
                  if key == "artifact" and isinstance(child, str)
                  else protocol_summary(child))
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [protocol_summary(child) for child in value]
    return value


class MCPClient:
    """One actual Elixir launcher with bounded nonblocking test I/O."""

    def __init__(self, elixir, config, token, name):
        environment = dict(os.environ)
        environment.update(RESEARCH_EXCHANGE_CONFIG=str(config), RESEARCH_EXCHANGE_TOKEN=token)
        self.process = subprocess.Popen(
            [str(elixir), str(ROOT.parent / "research_exchange_mcp/bin/stdio.exs")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, start_new_session=True, bufsize=0,
        )
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.buffer = b""
        self.sequence = 0
        self.name = name
        self.transcript = []
        self.stderr = ""
        self.closed = False

    def _send(self, value, timeout=15):
        data = memoryview(canonical(value) + b"\n")
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdin, selectors.EVENT_WRITE)
            while data:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise AssertionError("MCP stdin write timeout")
                try:
                    written = os.write(self.process.stdin.fileno(), data)
                except BlockingIOError:
                    continue
                except BrokenPipeError as error:
                    raise AssertionError("MCP launcher closed stdin") from error
                data = data[written:]

    def _receive(self, timeout=15):
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise AssertionError("MCP stdout response timeout")
                chunk = os.read(self.process.stdout.fileno(), 65_536)
                if not chunk:
                    raise AssertionError("MCP launcher exited before its response")
                self.buffer += chunk
                if len(self.buffer) > 131_073:
                    raise AssertionError("MCP response exceeded its wire bound")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return loads(line)

    def request(self, method, params=None):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}}
        self._send(request)
        response = self._receive()
        self.transcript.append({"request_summary": protocol_summary(request), "response": response})
        if response.get("jsonrpc") != "2.0" or response.get("id") != self.sequence:
            raise AssertionError("MCP response did not match the actual request ID")
        return response

    def initialize(self):
        response = self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "durable-acceptance", "version": "1"},
        })
        if response.get("result", {}).get("serverInfo", {}).get("name") != "research-exchange-durable-local":
            raise AssertionError("expected the explicitly selected durable MCP backend")
        notification = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        self._send(notification)
        self.transcript.append({"notification": notification})

    def tool(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        if self.closed:
            return self.process.returncode
        self.closed = True
        try:
            self.process.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            self.process.wait(timeout=6)
        except subprocess.TimeoutExpired:
            stop_process(self.process)
        self.stderr = self.process.stderr.read(65_536).decode("utf-8", errors="replace")
        self.process.stdout.close()
        self.process.stderr.close()
        return self.process.returncode


class DurableAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lean = Path(os.environ["RESEARCH_EXCHANGE_BRIDGE_LEAN_ROOT"]).resolve(strict=True)
        cls.fixtures = Path(os.environ["RESEARCH_EXCHANGE_BRIDGE_FIXTURES"]).resolve(strict=True)
        cls.elixir = Path(os.environ["RESEARCH_EXCHANGE_BRIDGE_ELIXIR"]).resolve(strict=True)
        cls.output = Path(os.environ["RESEARCH_EXCHANGE_BRIDGE_OUTPUT"]).resolve(strict=True)
        cls.profile = loads((cls.fixtures / "profile.json").read_bytes())
        cls.expected = (cls.fixtures / "expected.export").read_bytes()
        cls.alternate = (cls.fixtures / "alternate.export").read_bytes()
        if sha(cls.expected) != cls.profile["artifact_sha256"] or cls.expected == cls.alternate:
            raise AssertionError("the required exact-export fixtures do not match their profile")
        cls.checker = ControlledChecker(cls.lean)
        cls.checker.identities()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="durable-mcp-acceptance-")
        self.addCleanup(self.temporary.cleanup)
        self.instance = Path(self.temporary.name) / "instance"
        self.provisioned = provision(self.instance, self.profile, self.lean, Path(sys.executable))
        self.config_path = self.instance / "bridge.json"
        self.outer_path = self.instance / "mcp.json"
        self.config = loads(self.config_path.read_bytes())
        self.token = (self.instance / "contributor.token").read_text()
        self.key = receipt_key(self.config["receipt_key_base64"])
        self.store = Store(self.instance / "bridge.sqlite", self.key)
        self.library = self.provisioned["library"]
        self.clients = []
        self.workers = []
        self.jobs = []
        self.events = []
        self.secrets = [self.token, self.config["receipt_key_base64"]]
        self.configure(worker_enabled=False)

    def tearDown(self):
        for client in self.clients:
            client.close()
        for process, label in self.workers:
            stop_process(process)
            if process.stdout and not process.stdout.closed:
                stdout = process.stdout.read(65_536).decode("utf-8", errors="replace")
                stderr = process.stderr.read(65_536).decode("utf-8", errors="replace")
                process.stdout.close()
                process.stderr.close()
                self.events.append({"worker": label, "returncode": process.returncode,
                                    "stdout": stdout, "stderr": stderr})
        observations = []
        for job in self.jobs:
            observations.append({"job_id": job, "observation": self.store.inspect(job)})
        evidence = {
            "schema": "research-exchange/durable-runtime-case/v1",
            "test": self._testMethodName, "scope": "trusted-local-exact-reviewed-export-only",
            "events": self.events, "database_observations": observations,
            "clients": [{"name": c.name, "transcript": c.transcript,
                         "returncode": c.process.returncode, "stderr": c.stderr} for c in self.clients],
        }
        encoded = canonical(evidence).decode().replace(str(self.instance), "<private-instance>")
        for secret in self.secrets:
            if secret in encoded:
                raise AssertionError("private credential material was about to enter acceptance evidence")
        (self.output / f"{self._testMethodName}.json").write_text(encoded + "\n")

    def configure(self, **changes):
        self.config.update(changes)
        self.config_path.write_bytes(canonical(self.config) + b"\n")
        self.config_path.chmod(0o600)

    def client(self, *, token=None):
        client = MCPClient(self.elixir, self.outer_path, token or self.token, f"client-{len(self.clients) + 1}")
        self.clients.append(client)
        client.initialize()
        return client

    def success(self, response):
        self.assertNotIn("error", response)
        result = response["result"]
        self.assertIs(result["isError"], False)
        value = result["structuredContent"]
        # The text is generated by Elixir's canonical encoder while receipts are
        # generated by Python, so this is an actual cross-language comparison.
        self.assertEqual(result["content"], [{"type": "text", "text": canonical(value).decode()}])
        return value

    def refusal(self, response, code):
        self.assertNotIn("error", response)
        self.assertEqual(response["result"], {
            "isError": True, "content": [{"type": "text", "text": code}],
        })

    def assert_receipt(self, receipt, *, accepted=False):
        # success() compares these canonical bytes with the actual Elixir
        # encoder. Check the envelope independently with hashlib/hmac; the
        # control-character case also calls Elixir's receipt verifier directly.
        body = canonical(receipt["payload"])
        data = b"research-exchange/receipt/v1\n" + body
        self.assertEqual(receipt["sha256"], hashlib.sha256(data).hexdigest())
        self.assertTrue(hmac.compare_digest(receipt["server_mac"], hmac.new(self.key, data, "sha256").hexdigest()))
        self.assertIs(receipt["payload"]["mathematical_acceptance"], accepted)
        self.assertIs(receipt["payload"]["credit_issuance"], False)
        self.assertEqual(receipt["payload"]["acceptance_scope"], "exact-reviewed-export-only")

    def arguments(self, artifact=None, *, key="submit-1"):
        artifact = self.expected if artifact is None else artifact
        return {"idempotency_key": key, "library": self.library["id"],
                "revision": self.library["revision"], "snapshot_sha256": self.library["snapshot_sha256"],
                "generation": self.library["generation"], "target": self.profile["theorem"],
                "artifact": artifact.decode("utf-8"), "artifact_sha256": sha(artifact)}

    def submit(self, client, artifact=None, *, key="submit-1"):
        receipt = self.success(client.tool("proof_submit", self.arguments(artifact, key=key)))
        self.assert_receipt(receipt)
        return receipt

    def queue(self, client, submission, *, key="verify-1"):
        arguments = {"submission_id": submission["payload"]["id"], "idempotency_key": key}
        start = time.monotonic()
        receipt = self.success(client.tool("verification_request", arguments))
        self.assertLess(time.monotonic() - start, 4, "admission must not wait for checker completion")
        self.assertEqual(receipt["payload"]["status"], "queued")
        self.assert_receipt(receipt)
        job = receipt["payload"]["id"]
        if job not in self.jobs:
            self.jobs.append(job)
        return receipt

    def terminal(self, client, job, status="accepted"):
        def read():
            receipt = self.success(client.tool("receipt_get", {"id": job}))
            return receipt if receipt["payload"]["status"] == status else None
        receipt = wait_for(read, message=f"job did not reach {status}")
        self.assert_receipt(receipt, accepted=status == "accepted")
        return receipt

    def assert_effect(self, job, kind):
        evidence = self.store.inspect(job)
        self.assertTrue(evidence["terminal"])
        self.assertEqual(evidence["version"], 1)
        self.assertEqual(evidence["state"]["phase"], kind)
        self.assertEqual(evidence["outbox"], "complete")
        self.assertEqual(len(evidence["effects"]), 1)
        effect = evidence["effects"][0]
        self.assertEqual((effect["kind"], effect["before_version"], effect["after_version"]), (kind, 0, 1))
        self.assertEqual(loads(effect["receipt_json"]), evidence["receipt"])
        self.assertEqual(evidence["sqlite"], {"journal_mode": "wal", "synchronous": 2, "foreign_keys": 1})
        return evidence

    def assert_uncommitted(self, job, *, outbox="pending"):
        evidence = self.store.inspect(job)
        self.assertFalse(evidence["terminal"])
        self.assertEqual(evidence["version"], 0)
        self.assertEqual(evidence["effects"], [])
        self.assertEqual(evidence["state"]["phase"], "submitted")
        self.assertEqual(evidence["state"]["escrow"], 1)
        self.assertEqual(evidence["state"]["payouts"], 0)
        self.assertEqual(evidence["outbox"], outbox)
        self.assert_receipt(evidence["receipt"])
        return evidence

    def worker(self, job, *, label=None, **changes):
        label = label or f"worker-{len(self.workers) + 1}"
        config = dict(self.config, **changes)
        config_path = self.instance / f"{label}.json"
        config_path.write_bytes(canonical(config) + b"\n")
        config_path.chmod(0o600)
        process = subprocess.Popen(
            [sys.executable, "-I", "-B", str(ROOT / "worker.py"), "--config", str(config_path), "--job-id", job],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        self.workers.append((process, label))
        return process

    def finish_worker(self, process, expected=0):
        code = process.wait(timeout=30)
        self.assertEqual(code, expected, "worker must report its actual configured process outcome")

    def paused_worker(self, job, label):
        pause = self.instance / label
        process = self.worker(job, label=label, test_pause_after_check=str(pause), test_pause_job_id=job)
        ready = Path(str(pause) + ".ready")
        wait_for(ready.exists, message="worker did not reach the barrier after real proof checking")
        self.assertEqual(ready.read_text(), job)
        return process, Path(str(pause) + ".release")

    def test_complete_mcp_cycle_reaches_dual_checker_acceptance(self):
        self.configure(worker_enabled=True)
        client = self.client()
        listed = client.request("tools/list")["result"]["tools"]
        self.assertEqual([x["name"] for x in listed],
                         ["library_discover", "proof_submit", "receipt_get", "verification_request"])
        discovery = self.success(client.tool("library_discover", {}))
        self.assertEqual(discovery["libraries"], [self.library])
        self.assertEqual(discovery["core"], self.store.core)
        submission = self.submit(client)
        queued = self.queue(client, submission)
        job = queued["payload"]["id"]
        accepted = self.terminal(client, job)
        binding = accepted["payload"]["binding"]
        self.assertEqual({k: v for k, v in binding.items() if k != "submission_id"}, submission["payload"]["binding"])
        self.assertEqual(binding["submission_id"], submission["payload"]["id"])
        self.assertEqual(binding["artifact_sha256"], sha(self.expected))
        check = accepted["payload"]["details"]["controlled_check"]
        self.assertEqual(check["theorem"], self.profile["theorem"])
        self.assertEqual(check["profile_sha256"], queued["payload"]["details"]["profile_sha256"])
        self.assertEqual([x["checker"] for x in check["checkers"]], ["leanchecker", "lean4lean"])
        for item in check["checkers"]:
            self.assertEqual(item["exit_code"], 0)
            self.assertEqual(item["binary_sha256"], self.profile["tool_sha256"][item["checker"]])
            self.assertTrue(item["stdout"])
        self.assertEqual(self.success(client.tool("receipt_get", {"id": submission["payload"]["id"]})), submission)
        self.assertEqual(self.success(client.tool("verification_request", {
            "submission_id": submission["payload"]["id"], "idempotency_key": "verify-1"})), queued)
        self.assert_effect(job, "accepted")

    def test_unicode_receipt_is_canonical_across_python_and_elixir(self):
        token = secrets.token_urlsafe(40)
        self.secrets.append(token)
        principal = "researcher-é-λ"
        self.store.provision_grant(token, principal, [self.library["id"]],
                                   ["library:read", "proof:submit", "verification:request"], int(time.time()) + 3600)
        self.configure(worker_enabled=True)
        client = self.client(token=token)
        submission = self.submit(client)
        self.assertEqual(submission["payload"]["binding"]["contributor"], principal)
        job = self.queue(client, submission)["payload"]["id"]
        accepted = self.terminal(client, job)
        self.assertEqual(accepted["payload"]["binding"]["contributor"], principal)
        self.assert_effect(job, "accepted")

    def test_control_characters_and_literal_escapes_keep_canonical_identity(self):
        controls = "".join(chr(value) for value in range(32))
        principal = "researcher-é-λ/" + controls + r"\u000B\u000b"
        self.library = dict(self.library, id="fixture-é-λ/" + controls + r"\u000B")
        self.store.provision_library(self.library, self.profile)
        token = secrets.token_urlsafe(40)
        self.secrets.append(token)
        self.store.provision_grant(token, principal, [self.library["id"]],
                                   ["library:read", "proof:submit", "verification:request"], int(time.time()) + 3600)
        self.configure(worker_enabled=True)
        client = self.client(token=token)
        discovery = self.success(client.tool("library_discover", {}))
        self.assertEqual(discovery["libraries"], [self.library])
        submission = self.submit(client)
        queued = self.queue(client, submission)
        job = queued["payload"]["id"]
        accepted = self.terminal(client, job)
        receipts = [submission, queued, accepted]
        for receipt in receipts:
            self.assertEqual(receipt["payload"]["binding"]["contributor"], principal)
            self.assertEqual(receipt["payload"]["binding"]["library"], self.library["id"])

        # A literal backslash-u sequence is a different identity from the
        # corresponding control character, including the hex letter's case.
        replacements = [principal.replace("\x0b", r"\u000B"),
                        principal.replace(r"\u000B", "\x0b"),
                        principal.replace(r"\u000B", r"\u000b")]
        substituted = [dict(accepted, payload=dict(accepted["payload"], binding=dict(
            accepted["payload"]["binding"], contributor=value))) for value in replacements]
        values = ["\x0b", r"\u000B", r"\u000b", controls,
                  {controls: [principal, self.library["id"], None, True, False, 17],
                   r"\u000B": "é-λ", "\x0b": '"\\/'}]
        encodings = [canonical(value).decode() for value in values]
        self.assertEqual(len(set(encodings[:3])), 3)
        for value, encoding in zip(values, encodings, strict=True):
            self.assertEqual(loads(encoding), value)

        code = '''
        alias ResearchExchange.Evidence
        :ok = :io.setopts(:standard_io, encoding: :unicode)
        {input, _, ""} = :json.decode(IO.read(:stdio, :eof), :ok, %{null: nil})
        key = System.fetch_env!("RESEARCH_EXCHANGE_CANONICAL_KEY") |> Base.decode64!()
        output = %{
          "verified" => Enum.map(input["receipts"], &Evidence.verify_receipt?(&1, key)),
          "canonical_values" => Enum.map(input["values"], &Evidence.canonical/1)
        }
        IO.write(:stdio, Evidence.canonical(output))
        '''
        environment = dict(os.environ, RESEARCH_EXCHANGE_CANONICAL_KEY=self.config["receipt_key_base64"])
        result = subprocess.run(
            [str(self.elixir), "-r", str(ROOT.parent / "research_exchange_mcp/lib/research_exchange/evidence.ex"),
             "-e", code], input=canonical({"receipts": receipts + substituted, "values": values}),
            capture_output=True, env=environment, timeout=20, check=False)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        observed = loads(result.stdout)
        self.assertEqual(observed["verified"], [True, True, True, False, False, False])
        self.assertEqual(observed["canonical_values"], encodings)
        self.events.append({"actual_elixir_canonical_verifier": observed, "exit_code": result.returncode})
        self.assert_effect(job, "accepted")

    def test_valid_other_theorem_is_definitively_rejected(self):
        replay = self.checker.replay_export(self.alternate)
        self.assertEqual([x["checker"] for x in replay], ["leanchecker", "lean4lean"])
        self.events.append({"alternate_valid_proof_replay": replay, "artifact_sha256": sha(self.alternate)})
        self.configure(worker_enabled=True)
        client = self.client()
        submission = self.submit(client, self.alternate)
        job = self.queue(client, submission)["payload"]["id"]
        rejected = self.terminal(client, job, "rejected")
        self.assertEqual(rejected["payload"]["details"]["controlled_check"]["reason"], "export_profile_mismatch")
        evidence = self.assert_effect(job, "rejected")
        self.assertEqual(evidence["state"]["refund_amount"], 1)
        self.assertEqual(evidence["state"]["payouts"], 0)

    def test_stale_and_caller_authority_fields_cannot_be_admitted(self):
        client = self.client()
        for field, value in [("revision", "0" * 40), ("snapshot_sha256", "0" * 64),
                             ("generation", 2), ("target", "Other.valid_theorem"),
                             ("artifact_sha256", "0" * 64)]:
            with self.subTest(field=field):
                arguments = dict(self.arguments(), **{field: value})
                self.refusal(client.tool("proof_submit", arguments), "invalid_or_stale_binding")
        for field in ("trusted", "principal", "profile", "command", "checker_path", "success"):
            with self.subTest(extra=field):
                self.refusal(client.tool("proof_submit", dict(self.arguments(), **{field: "caller-controlled"})),
                             "invalid_arguments")
        for tool in ("accept", "settle", "observe", "observe_compute"):
            self.assertEqual(client.tool(tool, {})["error"]["code"], -32602)
        with self.store.connection() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM bridge_submissions").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM bridge_effects").fetchone()[0], 0)
        self.submit(client)

    def test_exact_retries_and_cross_tool_conflicts_are_durable(self):
        client = self.client()
        submission = self.submit(client)
        self.assertEqual(self.submit(client), submission)
        alternate = dict(self.arguments(self.alternate))
        self.refusal(client.tool("proof_submit", alternate), "idempotency_conflict")
        sid = submission["payload"]["id"]
        self.refusal(client.tool("verification_request", {"submission_id": sid, "idempotency_key": "submit-1"}),
                     "idempotency_conflict")
        queued = self.queue(client, submission)
        self.assertEqual(self.queue(client, submission), queued)
        self.refusal(client.tool("verification_request", {"submission_id": sid, "idempotency_key": "another-key"}),
                     "already_requested")
        self.assertEqual(client.close(), 0)
        restarted = self.client()
        self.assertEqual(self.submit(restarted), submission)
        self.assertEqual(self.queue(restarted, submission), queued)
        self.assert_uncommitted(queued["payload"]["id"])

    def test_distinct_principals_cannot_read_existing_shared_database_records(self):
        owner = self.client()
        submission = self.submit(owner)
        queued = self.queue(owner, submission)
        token = secrets.token_urlsafe(40)
        self.secrets.append(token)
        self.store.provision_grant(token, "other-researcher", [self.library["id"]],
                                   ["library:read", "proof:submit", "verification:request"], int(time.time()) + 3600)
        other = self.client(token=token)
        for identity in (submission["payload"]["id"], queued["payload"]["id"]):
            self.refusal(other.tool("receipt_get", {"id": identity}), "not_found")
        self.refusal(other.tool("verification_request", {
            "submission_id": submission["payload"]["id"], "idempotency_key": "foreign-verify"}), "not_found")
        self.assertEqual(self.success(owner.tool("receipt_get", {"id": queued["payload"]["id"]})), queued)
        self.assert_uncommitted(queued["payload"]["id"])

    def test_scopes_and_revocation_are_rechecked_on_actual_mcp_calls(self):
        owner = self.client()
        submission = self.submit(owner)
        token = secrets.token_urlsafe(40)
        self.secrets.append(token)
        self.store.provision_grant(token, "local-researcher", [self.library["id"]],
                                   ["library:read"], int(time.time()) + 3600)
        reader = self.client(token=token)
        self.success(reader.tool("library_discover", {}))
        self.refusal(reader.tool("proof_submit", self.arguments()), "forbidden")
        self.refusal(reader.tool("verification_request", {
            "submission_id": submission["payload"]["id"], "idempotency_key": "read-only"}), "forbidden")
        self.store.set_grant_enabled(self.token, False)
        self.assertEqual(owner.tool("proof_submit", self.arguments())["error"]["code"], -32001)
        self.store.set_grant_enabled(self.token, True)
        self.assertEqual(self.submit(owner), submission)

    def test_pending_dispatch_survives_launcher_restart(self):
        client = self.client()
        submission = self.submit(client)
        queued = self.queue(client, submission)
        job = queued["payload"]["id"]
        self.assert_uncommitted(job)
        self.assertEqual(client.close(), 0)
        self.configure(worker_enabled=True)
        restarted = self.client()
        accepted = self.terminal(restarted, job)
        self.assertEqual(self.queue(restarted, submission), queued)
        self.assertEqual(restarted.close(), 0)
        again = self.client()
        self.assertEqual(self.terminal(again, job), accepted)
        self.assert_effect(job, "accepted")

    def _revocation_after_check(self, authority):
        client = self.client()
        queued = self.queue(client, self.submit(client))
        job = queued["payload"]["id"]
        process, release = self.paused_worker(job, f"paused-{authority}")
        self.assert_uncommitted(job)
        if authority == "requester":
            self.store.set_grant_enabled(self.token, False)
            self.store.set_grant_enabled(self.token, True)
        else:
            self.store.set_verifier_enabled(False)
            self.store.set_verifier_enabled(True)
        release.touch()
        self.finish_worker(process)
        receipt = self.terminal(client, job, "verification_inconclusive")
        self.assertEqual(receipt["payload"]["details"]["reason"], "stale_authority")
        self.assert_uncommitted(job, outbox="paused")
        self.events.append({"real_checked_barrier": True, "revoked_and_regranted": authority,
                            "result": "fresh-epoch-commit-refused"})

    def test_requester_revoke_regrant_fences_a_real_prepared_check(self):
        self._revocation_after_check("requester")

    def test_verifier_revoke_regrant_fences_a_real_prepared_check(self):
        self._revocation_after_check("verifier")

    def test_requester_expiry_is_rechecked_after_real_proof_checking(self):
        owner = self.client()
        token = secrets.token_urlsafe(40)
        self.secrets.append(token)
        expires = int(time.time()) + 15
        self.store.provision_grant(token, "local-researcher", [self.library["id"]],
                                   ["library:read", "proof:submit", "verification:request"], expires)
        expiring = self.client(token=token)
        job = self.queue(expiring, self.submit(expiring))["payload"]["id"]
        process, release = self.paused_worker(job, "expires-after-check")
        self.assert_uncommitted(job)
        wait_for(lambda: int(time.time()) >= expires, timeout=20,
                 message="the provisioned short-lived grant did not expire")
        release.touch()
        self.finish_worker(process)
        self.assertEqual(expiring.tool("receipt_get", {"id": job})["error"]["code"], -32001)
        receipt = self.terminal(owner, job, "verification_inconclusive")
        self.assertEqual(receipt["payload"]["details"]["reason"], "unauthorized")
        self.assert_uncommitted(job, outbox="paused")
        self.events.append({"real_checked_barrier": True, "grant_expired_before_commit": True,
                            "result": "expired-requester-commit-refused"})

    def test_two_real_prepared_worker_processes_commit_one_effect(self):
        client = self.client()
        job = self.queue(client, self.submit(client))["payload"]["id"]
        first, release_first = self.paused_worker(job, "racing-first")
        second, release_second = self.paused_worker(job, "racing-second")
        self.assert_uncommitted(job)
        release_first.touch()
        release_second.touch()
        self.finish_worker(first)
        self.finish_worker(second)
        self.terminal(client, job)
        self.assert_effect(job, "accepted")
        self.events.append({"independent_prepared_workers": 2, "terminal_effects": 1,
                            "claim": "one durable effect; duplicate physical checking is permitted"})

    def _crash(self, point, artifact, verdict):
        client = self.client()
        submission = self.submit(client, artifact)
        queued = self.queue(client, submission)
        job = queued["payload"]["id"]
        self.assertEqual(client.close(), 0)
        process = self.worker(job, test_failpoint=point, test_job_id=job)
        expected_code = 86 if point == "before_commit" else 87
        self.finish_worker(process, expected_code)
        if point == "before_commit":
            self.assert_uncommitted(job)
        else:
            self.assert_effect(job, verdict)
        self.events.append({"failpoint": point, "actual_process_exit": expected_code,
                            "state_before_restart": self.store.inspect(job)})
        self.configure(worker_enabled=True)
        restarted = self.client()
        terminal = self.terminal(restarted, job, verdict)
        self.assertEqual(self.queue(restarted, submission), queued)
        self.assert_effect(job, verdict)
        self.assertEqual(restarted.close(), 0)
        final = self.client()
        self.assertEqual(self.terminal(final, job, verdict), terminal)
        self.assert_effect(job, verdict)

    def test_before_commit_process_crash_rolls_back_acceptance(self):
        self._crash("before_commit", self.expected, "accepted")

    def test_after_commit_process_crash_preserves_acceptance(self):
        self._crash("after_commit", self.expected, "accepted")

    def test_before_commit_process_crash_rolls_back_rejection(self):
        self._crash("before_commit", self.alternate, "rejected")

    def test_after_commit_process_crash_preserves_rejection(self):
        self._crash("after_commit", self.alternate, "rejected")

    def test_unavailable_checker_is_inconclusive_and_operator_retry_recovers(self):
        self.configure(worker_enabled=True, lean_root=str(self.instance / "missing-pinned-lean"))
        client = self.client()
        submission = self.submit(client)
        queued = self.queue(client, submission)
        job = queued["payload"]["id"]
        inconclusive = self.terminal(client, job, "verification_inconclusive")
        self.assertEqual(inconclusive["payload"]["details"]["reason"], "checker_unavailable")
        self.assert_uncommitted(job, outbox="paused")
        self.assertEqual(self.queue(client, submission), queued)
        self.assertEqual(client.close(), 0)
        self.configure(lean_root=str(self.lean))
        self.store.retry(job)
        recovered = self.client()
        self.terminal(recovered, job)
        self.assert_effect(job, "accepted")

    def test_persisted_identity_and_terminal_history_are_immutable(self):
        self.configure(worker_enabled=True)
        client = self.client()
        submission = self.submit(client)
        job = self.queue(client, submission)["payload"]["id"]
        terminal = self.terminal(client, job)
        sid = submission["payload"]["id"]
        statements = [
            ("UPDATE bridge_submissions SET artifact=? WHERE id=?", (b"changed", sid)),
            ("DELETE FROM bridge_submissions WHERE id=?", (sid,)),
            ("UPDATE bridge_jobs SET binding_json='{}' WHERE id=?", (job,)),
            ("UPDATE bridge_jobs SET state_json='{}' WHERE id=?", (job,)),
            ("DELETE FROM bridge_jobs WHERE id=?", (job,)),
            ("UPDATE bridge_effects SET kind='rejected' WHERE job_id=?", (job,)),
            ("DELETE FROM bridge_effects WHERE job_id=?", (job,)),
            ("UPDATE bridge_requests SET request_sha256='changed' WHERE request_id='submit-1'", ()),
            ("DELETE FROM bridge_requests WHERE request_id='submit-1'", ()),
            ("UPDATE bridge_libraries SET profile_sha256='changed' WHERE id=?", (self.library["id"],)),
            ("UPDATE bridge_grants SET principal='substituted'", ()),
            ("UPDATE bridge_attempts SET observation_json='{}' WHERE job_id=?", (job,)),
            ("DELETE FROM bridge_attempts WHERE job_id=?", (job,)),
            ("DELETE FROM bridge_outbox WHERE job_id=?", (job,)),
            ("DELETE FROM bridge_authority", ()),
            ("UPDATE bridge_meta SET value='changed' WHERE key='core'", ()),
            ("DELETE FROM bridge_meta WHERE key='core'", ()),
        ]
        for statement, parameters in statements:
            with self.subTest(statement=statement):
                with self.assertRaises(sqlite3.IntegrityError):
                    with self.store.transaction() as connection:
                        connection.execute(statement, parameters)
        self.assertEqual(self.success(client.tool("receipt_get", {"id": job})), terminal)
        self.assert_effect(job, "accepted")
        self.events.append({"rejected_sql_history_mutations": len(statements)})

    def test_substituted_prepared_bindings_profiles_and_versions_cannot_commit(self):
        client = self.client()
        job = self.queue(client, self.submit(client))["payload"]["id"]
        prepared = self.store.prepare(job)
        checked = self.checker.check(loads(prepared.profile_json), prepared.artifact)
        changes = [
            ("binding_json", canonical({}).decode(), "stored_identity_mismatch"),
            ("config_json", canonical({}).decode(), "stored_identity_mismatch"),
            ("profile_json", canonical({}).decode(), "stored_identity_mismatch"),
            ("profile_sha256", "0" * 64, "stored_identity_mismatch"),
            ("artifact", self.alternate, "stored_identity_mismatch"),
            ("token_hash", "0" * 64, "stored_identity_mismatch"),
            ("version", prepared.version + 1, "stale_version"),
            ("authority_epoch", prepared.authority_epoch + 1, "stale_authority"),
            ("requester_epoch", prepared.requester_epoch + 1, "stale_authority"),
            ("library_epoch", prepared.library_epoch + 1, "stale_authority"),
        ]
        for field, value, code in changes:
            with self.subTest(field=field):
                with self.assertRaises(BridgeError) as failure:
                    self.store.commit(replace(prepared, **{field: value}), checked)
                self.assertEqual(failure.exception.code, code)
                self.assert_uncommitted(job)
        for field in ("profile_sha256", "artifact_sha256"):
            with self.assertRaises(BridgeError) as failure:
                self.store.commit(prepared, replace(checked, **{field: "0" * 64}))
            self.assertEqual(failure.exception.code, "stored_identity_mismatch")
        self.store.commit(prepared, checked)
        self.terminal(client, job)
        self.assert_effect(job, "accepted")
        self.events.append({"real_dual_check_prepared_substitution_controls": len(changes) + 2})


if __name__ == "__main__":
    unittest.main(verbosity=2)
