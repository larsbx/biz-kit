# Agent-agnostic coordination and signed TaskCore run intents

Date: 2026-10-24. Status: **architecture corrected while PR #91 is draft;
staging-only**. No production agent coordinator is deployed.

## Principle: agents and execution backends are pluggable

The coordinator must treat agents as scoped principals, **not** as Hermes,
Pi, a particular model vendor, a specific prompt format, or an OCI process.
An agent may be backed by an embedded library, a local process, an isolated
sandbox, a hosted/remote agent, a queue worker, or another implementation.
The choice of execution mechanism belongs to a separately authorized,
versioned **execution profile**.

Biz-kit defines *what* work is authorized, the current task/version, and
the admissible effects. The execution adapter defines *how* to launch,
observe and cancel one attempt. Neither an OpenShell gateway nor a model
session acquires business authority merely by running.

The implementation boundaries:

| Layer | Owner | Responsibility |
| --- | --- | --- |
| Business authorization | Identity, TaskCore, CoopSubstrate ledger | Scopes, signatures, grants, task lifecycle, DoD and signed run intents |
| Engine-independent coordination contract | `AgentCore.ExecutionPort` | `launch/3`, `poll/1`, `cancel/2`; return opaque execution handles and candidate references |
| Approved execution profile lookup | `AgentCore.Profiles` | Resolve an immutable profile ID + digest against a **trusted** registry, reject drift, disabled profiles, unknown adapters |
| Backend adapters | Deployable integrations, **not TaskCore** | Sandbox, service API, background worker, VM, CLI, etc.; no assumption of a model or vendor |
| Operational execution state | Future coordinator/outbox | Leases, attempts, timeouts, deduplication, cancellations, output collection, and crash recovery |
| Accepted business effects | Existing signed ledger and domain gates | Typed task commands, evidence custody, independent review, and domain-specific authorization |

`AgentCore` has no vendor SDK dependency, no TaskCore dependency and no
runtime daemon. Its registry receives approved **module references** from
trusted host configuration; it never converts an agent-provided string
to an atom or executable module. The registry intentionally does not
authorize reads or execution by itself.

## Signed run-intent contract

New event types are registered by `TaskCore.AgentRuns.event_types/0` through
the existing `TaskCore.Admission` and CoopSubstrate appender.

| Event | Signed by | State effect |
| --- | --- | --- |
| `TaskAgentRunRequestedV1` | Authorized task operator | Creates one run ID tied to exact task version, last event, DoD digest, agent principal and live project suggester grant, immutable **execution_profile_id + execution_profile_digest**, and generic max duration/output bounds |
| `TaskAgentRunCancelledV1` | Authorized task operator | Marks the run cancelled; cannot undo existing accepted ledger facts |

**There are deliberately no mandatory container images, sandbox policies,
CPU/memory measurements, model IDs, SDK names, or provider URLs in the run
event.** An administrator-reviewed execution profile may contain such
runtime-specific settings. A remote hosted agent can have a different
profile from an OpenShell-isolated agent without changing TaskCore,
the signed event schema, or the coordinator protocol.

The signed profile digest pins the **execution configuration decision** in
business history. The host must verify that the registry entry is current,
approved, and corresponds to that exact digest and allowed data disclosure
policy; the existence of a digest is not proof of profile approval.

Run IDs are unique per (chapter, tenant, project). The first accepted event
owns the ID permanently. Same-envelope retry returns the original accepted
ledger record, while changing the event under the same ID is refused.
Run intents do not modify task versions or independently complete work.

`AgentRuns.runnable?/2` and `AgentCandidates.current?/3` check current
committed task scope, version, last event, DoD reference and active grants.
They must be rechecked immediately before start and result consideration;
any **business command** is rechecked by the signed serialized ledger gate.

## Identity is distinct from implementation

An agent principal is platform identity, not a process ID or framework
instance. It may change execution profiles without inheriting extra
rights. A suggester grant merely binds its identity and enables existing
suggestion semantics; it does **not** grant generic task reads, execution,
or domain business writes. A future separate execution/read authorization
gate is required before a host can act on signed run intent.

Tasks must avoid leaking private learner/customer/driver/location data
through tickets or direct runtime environment access. Backends get
only authorized task context via typed tool/read APIs; credential scopes
and agent memory are never sources of business authority.

## Capability negotiation and lifecycle

A future coordinator will resolve an approved execution profile, then
verify required capabilities against what the selected adapter supports.
For example, `streaming`, `tool_calls`, `files`, `gpu`, `network`,
`long_running`, `data_residency`, and `cancellation` may differ by
engine and deployment. Unsupported capabilities must fail closed, never
silently fall back to a less restrictive engine.

`AgentCore.ExecutionPort` intentionally exposes only launch/status/cancel
at this stage. Dispatch's existing turn-based and streaming ports remain
distinct application-level protocols. A future bridge can adapt those ports
to the generic execution interface without making either one canonical.

Operational state may include adapter name, attempt ID, immutable execution
handle, logs, output digest and metrics. It must not create a competing
business history. A cancellation response only records a request; the
coordinator must independently observe termination/revocation effects.

## Validation and rollout

PR #91 contains offline profile-lookup tests with **two unrelated adapter
implementations** (sandbox-shaped and service-shaped), pure TaskCore
ticket/run tests, a PostgreSQL-backed signed-ledger run acceptance suite
and the optional OpenShell-specific isolated smoke. The OpenShell
experiment is **one plugin, not a dependency for TaskCore or AgentCore**.

No real engine, host authorization service, durable delivery/outbox,
runtime-secret enforcement, active revocation, custody acceptance, or
production deployment is established by these files. Before enabling
any autonomous business effects, issue #92 still requires:

1. Separate current task-read and run-execution authorization, tenant quotas,
   published profiles and capability negotiation (with explicit approvals).
2. Durable ledger-derived launch intents, idempotent effect IDs, leases,
   replays, crash recovery, immutable execution-handle reconciliation.
3. Each tool invocation routed through authenticated, scoped domain admission
   with current revocation/consent checks, never through raw service secrets.
4. Exact evidence receipt and independent DoD review; all agent output starts
   as a candidate, not an accepted fact.
5. Conformance with at least **two genuinely different real backends**;
   fail-closed capability mismatch and selection drift. OpenShell staging,
   if selected, needs pinned gateway/SDK/image/policy and isolation tests.
6. Production security work remains gated by existing biz-kit identity,
   portal and administrative authorization obligations.

See [draft PR #91](https://github.com/larsbx/biz-kit/pull/91),
[issue #92](https://github.com/larsbx/biz-kit/issues/92),
[AgentCore execution port](../../apps/agent_core/lib/agent_core/execution_port.ex),
[TaskCore run intents](../../apps/task_core/lib/task_core/agent_runs.ex),
[OpenShell optional experiment](../../experiments/openshell_taskcore/README.md),
[one-source-of-truth architecture](2026-10-11-single-source-of-truth.md).
