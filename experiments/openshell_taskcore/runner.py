"""Non-authoritative OpenShell sandbox smoke for a ledger-selected TaskCore task.

This is an EXPERIMENT, not a business-command adapter. A trusted biz-kit host
must authenticate the caller, read the committed task and authorize execution
before constructing a Ticket. Nothing here verifies a signature or appends to
CoopSubstrate. Neither stdout nor this receipt is Definition-of-Done evidence.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import re
import secrets
from typing import Any, Mapping


_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_MAX_OUTPUT_BYTES = 4096

# The deliberately inert worker exercises the sandbox lifecycle and typed
# result boundary. It is NOT an LLM, Hermes agent or delegated command signer.
_WORKER = """
import json
import sys
t = json.loads(sys.stdin.read())
print(json.dumps({
    "schema": "bizkit.agent_candidate.v1",
    "chapter_id": t["chapter_id"],
    "tenant_id": t["tenant_id"],
    "project_id": t["project_id"],
    "task_id": t["task_id"],
    "task_version": t["task_version"],
    "source_event_id": t["source_event_id"],
    "action": "request_review",
    "summary": "Sandbox smoke completed; no business action was taken."
}, sort_keys=True, separators=(",", ":")))
"""


class HandoffError(ValueError):
    """Malformed handoff or untrustworthy candidate output."""


class ExecutionError(RuntimeError):
    """Sandbox failed, or cleanup could not be confirmed."""


@dataclass(frozen=True)
class Ticket:
    chapter_id: str
    tenant_id: str
    project_id: str
    task_id: str
    task_version: int
    source_event_id: str
    definition_digest: str

    @classmethod
    def parse(cls, raw: Mapping[str, Any]) -> "Ticket":
        if not isinstance(raw, Mapping) or set(raw) != set(cls.__dataclass_fields__):
            raise HandoffError("ticket must contain only the specified fields")
        for field in ("chapter_id", "tenant_id", "project_id", "task_id", "source_event_id"):
            value = raw[field]
            if not isinstance(value, str) or not _SEGMENT.fullmatch(value):
                raise HandoffError(f"invalid {field}")
        if type(raw["task_version"]) is not int or not (1 <= raw["task_version"] <= 2**31 - 1):
            raise HandoffError("invalid task_version")
        if (not isinstance(raw["definition_digest"], str)
                or not _DIGEST.fullmatch(raw["definition_digest"])):
            raise HandoffError("invalid definition_digest")
        return cls(**raw)

    def encoded(self) -> bytes:
        # Re-validate even a manually constructed dataclass.
        Ticket.parse(asdict(self))
        return json.dumps(asdict(self), sort_keys=True, separators=(",", ":")).encode("utf-8")


@dataclass(frozen=True)
class CandidateReceipt:
    source_event_id: str
    task_id: str
    sandbox_id: str
    output_sha256: str
    candidate: Mapping[str, Any]

    # Not signed, not ledger-accepted, not a custody receipt.


def _valid_name(value: str) -> bool:
    return isinstance(value, str) and _SEGMENT.fullmatch(value) is not None


def _candidate(stdout: str, ticket: Ticket) -> Mapping[str, Any]:
    if not isinstance(stdout, str) or len(stdout.encode("utf-8")) > _MAX_OUTPUT_BYTES:
        raise HandoffError("missing or oversized sandbox output")
    try:
        value = json.loads(stdout)
    except (ValueError, TypeError) as exc:
        raise HandoffError("sandbox output is not valid JSON") from exc
    expected = {
        "schema": "bizkit.agent_candidate.v1",
        "chapter_id": ticket.chapter_id,
        "tenant_id": ticket.tenant_id,
        "project_id": ticket.project_id,
        "task_id": ticket.task_id,
        "task_version": ticket.task_version,
        "source_event_id": ticket.source_event_id,
        "action": "request_review",
    }
    if not isinstance(value, dict) or any(value.get(k) != v for k, v in expected.items()):
        raise HandoffError("sandbox output does not match source task and scope")
    if set(value) != set(expected) | {"summary"}:
        raise HandoffError("unexpected sandbox output fields")
    if (not isinstance(value["summary"], str) or
            not (1 <= len(value["summary"]) <= 256)):
        raise HandoffError("invalid candidate summary")
    return value


def run_sandbox(client: Any, ticket: Ticket, *, workspace: str,
                workload_template: str) -> CandidateReceipt:
    """Execute fixed inert worker in a pre-approved OpenShell workload template.

    The client must have create/exec/delete only for the restricted workspace.
    No caller-supplied executable, network rule, provider or sandbox policy is
    accepted. The template's image/policy must be pinned and reviewed OUTSIDE
    this function. A receipt is returned only after confirmed cleanup.
    """
    if not isinstance(ticket, Ticket):
        raise HandoffError("expected a Ticket")
    payload = ticket.encoded()
    if not _valid_name(workspace) or not _valid_name(workload_template):
        raise HandoffError("invalid workspace or approved template name")

    name = "bk-smoke-" + secrets.token_hex(10)
    sandbox = client.create_from_template(
        workspace=workspace,
        workload_template=workload_template,
        name=name,
        labels={"managed-by": "biz-kit", "purpose": "taskcore-smoke"},
    )
    if not sandbox.id or sandbox.name != name or sandbox.workspace != workspace:
        # An unusable creation response requires operator reconciliation.
        # There may be an orphan; do not blindly delete an unknown sandbox ID.
        raise ExecutionError("sandbox identity mismatch after creation")

    try:
        ready = client.wait_ready(name, workspace=workspace, timeout_seconds=120)
        if ready.id != sandbox.id:
            raise ExecutionError("sandbox changed identity before execution")

        result = client.exec(
            name,
            ["python3", "-c", _WORKER],
            workspace=workspace,
            stdin=payload,
            timeout_seconds=30,
            no_login_shell=True,
        )
        if type(result.exit_code) is not int or result.exit_code != 0:
            raise ExecutionError("sandbox command failed")
        candidate = _candidate(result.stdout, ticket)
        digest = hashlib.sha256(result.stdout.encode("utf-8")).hexdigest()
        receipt = CandidateReceipt(ticket.source_event_id, ticket.task_id,
                                   sandbox.id, digest, candidate)
    finally:
        deletion = client.delete(name, workspace=workspace)
        if deletion.sandbox_id != sandbox.id:
            raise ExecutionError("deletion ID mismatch; manual reconciliation required")
        client.wait_deleted(name, workspace=workspace, timeout_seconds=60,
                            expected_sandbox_id=sandbox.id)

    return receipt


def local_smoke(ticket_data: Mapping[str, Any], *, workspace: str,
                workload_template: str) -> CandidateReceipt:
    """Explicit local operator demo using the selected OpenShell CLI gateway.

    This convenience function does NOT perform biz-kit authorization. Never
    expose it as an HTTP/MCP endpoint or invoke it with unverified task data.
    """
    from openshell import SandboxClient  # optional pinned 0.1.x SDK
    ticket = Ticket.parse(ticket_data)
    with SandboxClient.from_active_cluster() as client:
        return run_sandbox(client, ticket, workspace=workspace,
                           workload_template=workload_template)
