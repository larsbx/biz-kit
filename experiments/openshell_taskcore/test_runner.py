"""Offline contract tests: no gateway, secrets, model or business ledger needed."""

import json
from types import SimpleNamespace
import unittest

from runner import (ExecutionError, HandoffError, Ticket, run_sandbox)


TICKET = {
    "chapter_id": "org1",
    "tenant_id": "tenant1",
    "project_id": "project1",
    "task_id": "task1",
    "task_version": 3,
    "source_event_id": "evt-123",
    "definition_digest": "a" * 64,
}


def candidate(overrides=None):
    body = {
        "schema": "bizkit.agent_candidate.v1",
        "chapter_id": "org1",
        "tenant_id": "tenant1",
        "project_id": "project1",
        "task_id": "task1",
        "task_version": 3,
        "source_event_id": "evt-123",
        "action": "request_review",
        "summary": "Sandbox smoke completed; no business action was taken.",
    }
    body.update(overrides or {})
    return json.dumps(body)


class MockSandbox:
    def __init__(self):
        self.calls = []
        self.stdout = candidate()
        self.exit_code = 0
        self.ready_id = "sandbox-original"
        self.deleted_id = "sandbox-original"
        self.fail_at = None

    def create_from_template(self, **kwargs):
        self.calls.append(("create", kwargs))
        if self.fail_at == "create":
            raise RuntimeError("gateway down")
        return SimpleNamespace(id="sandbox-original", name=kwargs["name"],
                               workspace=kwargs["workspace"])

    def wait_ready(self, name, **kwargs):
        self.calls.append(("ready", kwargs))
        if self.fail_at == "ready":
            raise RuntimeError("sandbox timeout")
        return SimpleNamespace(id=self.ready_id)

    def exec(self, name, command, **kwargs):
        self.calls.append(("exec", (name, command, kwargs)))
        if self.fail_at == "exec":
            raise RuntimeError("gRPC lost")
        return SimpleNamespace(exit_code=self.exit_code, stdout=self.stdout)

    def delete(self, name, **kwargs):
        self.calls.append(("delete", kwargs))
        if self.fail_at == "delete":
            raise RuntimeError("delete failed")
        return SimpleNamespace(sandbox_id=self.deleted_id)

    def wait_deleted(self, name, **kwargs):
        self.calls.append(("wait_deleted", kwargs))
        if self.fail_at == "wait_deleted":
            raise RuntimeError("sandbox retained")


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.client = MockSandbox()
        self.ticket = Ticket.parse(TICKET)

    def run_it(self):
        return run_sandbox(self.client, self.ticket,
                           workspace="default", workload_template="approved-worker")

    def names(self):
        return [call[0] for call in self.client.calls]

    def test_success_returns_non_authoritative_candidate_after_cleanup(self):
        receipt = self.run_it()
        self.assertEqual(receipt.task_id, TICKET["task_id"])
        self.assertEqual(receipt.sandbox_id, "sandbox-original")
        self.assertEqual(len(receipt.output_sha256), 64)
        self.assertEqual(receipt.candidate["action"], "request_review")
        self.assertEqual(self.names(),
                         ["create", "ready", "exec", "delete", "wait_deleted"])
        _, (_, command, kwargs) = self.client.calls[2]
        self.assertEqual(command[:2], ["python3", "-c"])
        self.assertEqual(json.loads(kwargs["stdin"]), TICKET)
        self.assertNotIn("provider", self.client.calls[0][1])
        self.assertEqual(self.client.calls[-1][1]["expected_sandbox_id"],
                         "sandbox-original")

    def test_wrong_scope_or_source_rejected_and_cleaned_up(self):
        for change in [{"tenant_id": "other"}, {"source_event_id": "other"},
                       {"task_version": 4}, {"action": "execute"}]:
            with self.subTest(change=change):
                client = MockSandbox()
                client.stdout = candidate(change)
                with self.assertRaises(HandoffError):
                    run_sandbox(client, self.ticket, workspace="default",
                                workload_template="approved-worker")
                self.assertEqual([c[0] for c in client.calls][-2:],
                                 ["delete", "wait_deleted"])

    def test_nonzero_exit_is_failure_and_cleanup(self):
        self.client.exit_code = 1
        with self.assertRaises(ExecutionError):
            self.run_it()
        self.assertEqual(self.names()[-2:], ["delete", "wait_deleted"])

    def test_gateway_error_is_failure_and_cleanup(self):
        self.client.fail_at = "exec"
        with self.assertRaises(RuntimeError):
            self.run_it()
        self.assertEqual(self.names()[-2:], ["delete", "wait_deleted"])

    def test_sandbox_identity_replacement_is_refused(self):
        self.client.ready_id = "sandbox-reused-name"
        with self.assertRaises(ExecutionError):
            self.run_it()
        self.assertNotIn("exec", self.names())
        self.assertEqual(self.names()[-2:], ["delete", "wait_deleted"])

    def test_failure_before_ready_still_cleans(self):
        self.client.fail_at = "ready"
        with self.assertRaises(RuntimeError):
            self.run_it()
        self.assertEqual(self.names(), ["create", "ready", "delete", "wait_deleted"])

    def test_unknown_delete_id_fails_closed(self):
        self.client.deleted_id = "different"
        with self.assertRaises(ExecutionError):
            self.run_it()
        self.assertEqual(self.names()[-1], "delete")

    def test_cleanup_failure_cannot_report_success(self):
        self.client.fail_at = "wait_deleted"
        with self.assertRaises(RuntimeError):
            self.run_it()

    def test_oversize_and_invalid_output_rejected(self):
        for stdout in ["garbage", "x" * 4097, candidate({"extra": "unexpected"})]:
            with self.subTest(stdout=stdout[:20]):
                client = MockSandbox()
                client.stdout = stdout
                with self.assertRaises(HandoffError):
                    run_sandbox(client, self.ticket, workspace="default",
                                workload_template="approved-worker")

    def test_malformed_tickets_refused_before_create(self):
        for bad in [
            {**TICKET, "tenant_id": "../other"},
            {**TICKET, "task_version": True},
            {**TICKET, "definition_digest": "not-a-digest"},
            {**TICKET, "unauthorized": "yes"},
        ]:
            with self.subTest(bad=bad):
                with self.assertRaises(HandoffError):
                    self.ticket = Ticket.parse(bad)
        self.assertEqual(self.client.calls, [])

    def test_bad_template_fails_before_create(self):
        with self.assertRaises(HandoffError):
            run_sandbox(self.client, self.ticket, workspace="default",
                        workload_template="../arbitrary")
        self.assertEqual(self.client.calls, [])


if __name__ == "__main__":
    unittest.main()
