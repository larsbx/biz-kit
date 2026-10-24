# Signed TaskCore agent runs, staged OpenShell backend

Date: 2026-10-24. Status: **additive signed-intent stage in PR #91; staging-only**.

## Decision

Agent coordination belongs to biz-kit, but agents never become authoritative
business writers. OpenShell is a replacable sandbox execution backend; Hermes,
Pi, and additional model runtimes remain provider-neutral workers.

A signed `TaskAgentRunRequestedV1` is **operator authorization to consider
one bounded run**. It is not a delegation, a DoD review, permission to read
task records, or a substitute for runtime security policies. Only a trusted
host can execute a requested run after independently verifying the current
task, read grant, operator scope, sandbox template, policy, worker identity,
resources and workspace admission. Do not automatically dispatch every
ledger-visible intent until the later coordinator/outbox gate is implemented.

## Ledger event contract

New types are registered through `TaskCore.AgentRuns.event_types/0`,
`TaskCore.Admission` and `TaskCore.State` using the existing signed
CoopSubstrate appender:

| Event | Signer | Effects |
| --- | --- | --- |
| `TaskAgentRunRequestedV1` | Active matching task operator grant | Records immutable run ID, task revision, current source event and DoD digest, named suggester agent/grant, approved-template **reference**, image/policy digests and per-run CPU, memory, time and output limits. |
| `TaskAgentRunCancelledV1` | Any current authorized operator for the scope | Advances run status to cancelled; later `runnable?/2` refuses it. |

Run identifiers are unique per (chapter, tenant, project); the first signed
request owns the ID forever. Same-envelope retry returns the accepted
record through `CoopSubstrate.Tasks.duplicate/2` without another append.
Conflicting reuse of a run ID is refused. Task version and DoD reference
are checked against **committed state at append time**, not against a
client-supplied projection. Existing task lifecycle and timing versions
are not advanced by a run intent.

The request has **no open-ended agent tool list**. It cannot carry arbitrary
program code, prompts, credentials, customer/location records, student data,
or the task title. Stored digests are identifiers, not a guarantee that
approved images/templates/policies have been deployed. That binding and
runtime approval are a separate host obligation.

`TaskCore.AgentRuns.runnable?/2` recomputes eligibility using current
committed TaskCore state, including current suggester grant, operator grant,
task lifecycle state, task version, last event ID and DoD digest. It
returns a minimal content-free sandbox ticket and pinned references only
after those checks. Call before provisioning and **again after execution**
before any candidate can be processed.

## Who owns what

| Record | Authority |
| --- | --- |
| Task state, granted scopes, run intent/cancellation | Signed CoopSubstrate ledger |
| Workflow rules, eligibility, versions | TaskCore pure admission and projection |
| Sandbox status/heartbeat/lease, stdout, internal crash recovery | Operational outbox and OpenShell gateway, never a competing business log |
| Prompt/model/tool work | Hermes/Pi or other agent runtime inside sandbox |
| Validated candidate result | Experimental adapter; no business state change |
| Task evidence, review, completion, inventory/orders | Existing authenticated domain command gate and explicit evidence custody |

The `AgentCandidates.plan/2` check on a suggester grant does not authorize
private task reads, execution or all kinds of suggestion. No execution
privilege follows automatically from possession of the signed run event.
A worker can never grant itself authority by returning a valid-looking
ticket, output hash, or OpenShell sandbox ID.

## Remaining work: issue #92

1. **Control-plane authorization**: explicit run-execution and task-read
   grants; tenant safe query; administrator-approved template/policy/image
   registry; bounded tenant quota and per-agent concurrency.
2. **Durable outbox**: lease attempts and renewals, stable effect ID
   derived from run intent event ID, idempotent worker launch, cancellation,
   restart reconciliation, sandbox immutable-ID fencing and orphan cleanup.
   Deleting a sandbox by reused name without an identity check is forbidden.
3. **Typed tools**: assign only accepted per-command capability grants,
   validate tool schemas, recheck current identity/tenant/consent and enforce
   domain admission for every business action. Model output cannot invoke
   ledger appends with service credentials.
4. **Evidence path**: separately store candidate bytes, verify immutable
   digest/custody, submit with operator signature, independent DoD review.
   Agent stdout never completes a task.
5. **Staging acceptance**: pin matching NVIDIA 0.1.x SDK and gateway and
   approved OCI image; prove effective network/filesystem policy, denial of
   out-of-policy APIs, revocation while a run is live, provider isolation,
   recovery under all crash windows, controlled rollout and rollback.
6. **Platform security prerequisites**: existing biz-kit identity/session
   and administrator-transaction P1s remain independent production gates.
   Do not expose agents to real user data before they close.

The current stage has **pure TaskCore unit tests**, **genuine
PostgreSQL-backed signed-ledger regression tests** and **offline Python
sandbox fake-client tests**. Their existence does not establish CI passes
on the current PR head, an actual OpenShell gateway or production safety.
Check the exact PR head and hosted jobs before merging.

See [PR #91](https://github.com/larsbx/biz-kit/pull/91),
[issue #92](https://github.com/larsbx/biz-kit/issues/92),
[TaskCore agent candidates](../../apps/task_core/lib/task_core/agent_candidates.ex),
[OpenShell experiment](../../experiments/openshell_taskcore/README.md),
[one-source-of-truth architecture](2026-10-11-single-source-of-truth.md).
