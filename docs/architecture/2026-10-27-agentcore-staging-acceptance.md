# AgentCore staging delivery acceptance — 2026-10-27

Status: **staging regression tests, not a production coordinator or deployment.**

The agent coordinator is already implemented as an opt-in **staging-only**
bridge in `AgentOpsStore.Coordinator` with `TaskCore.Dispatcher`,
`TaskCore.AgentRuns.authorized?/3`, `AgentCore.Preflight`, and
`AgentOpsStore.Postgres`. Do not create an alternative business task queue,
second ledger or framework-specific host. The existing business authority is
the signed CoopSubstrate ledger; `agent_ops` contains only operational effects.

## This acceptance slice

The new real-PostgreSQL tests at
`apps/agent_ops_store/test/dispatch_integration_test.exs` combine:

- A trusted **in-memory TestHost** TaskCore replay fixture with scoped
  operator, suggester and *separate* governance read/execute grants. This
  fixture is not a substitute for cryptographic ledger verification; the
  signed append path has its own tests.
- Two intentionally different agent runtime adapters (`LocalWorker` and
  `RemoteWorker`) that implement the same `ExecutionPort` and
  `RecoveryPort`. They have no Hermes/Pi/OpenShell dependency, and the
  operator's signed run event is unchanged between profiles.
- Actual PostgreSQL `agent_ops` registration/lease CAS. The first delivery
  commits its lease before executing the adapter. A repeated delivery
  returns already dispatched, never a second launch.
- Revocation *between preflight and durable-claim recheck* to demonstrate
  that a run is fenced before backend launch, with no agent tool or write
  capabilities inherited from a suggester grant.
- An ambiguous backend reference acknowledgment that leaves the attempt
  leased rather than speculatively retrying; real recovery requires
  effect-ID-bound, independently verified backend observations.
- An existing backend after task access revocation: the coordinator fences
  the attempt and requests termination, but does **not** falsely claim it
  already stopped.

The tests are run by the existing volume-backed PostgreSQL CI with the
named Docker volume. The same storage configuration is usable with Podman
where its Compose provider supports it; no Podman runtime claim is made from
Docker-only CI.

## Mandatory production gates still open

This change does **not** provide an independently authenticated production
`AgentOpsStore.Host`, user/tenant-safe read grants, admin-approved immutable
profile publication, validated backend recovery receipts, protected and
versioned worker credentials, a mounted external executor, or formal
cross-node launch crash-fault acceptance.

Business tool invocations must recheck present consent and fresh signed
authority. `AgentOpsStore.ToolProxy` deliberately supports read-only task
access in staging and has **no general business-write tool**. Candidate
outputs are not task completion, DoD review, or signed business facts.

Required next: hosted Postgres acceptance with a *real signed ledger*
fixture, proof-bound recovery against at least two genuinely different
agent execution backends, cross-process transactional concurrency tests,
secret handling, rootless Podman parity if selected, and controlled rollout
with a rollback path. Do not enable general agent business writes or production
execution merely because this test suite is green.

See [Issue #92](https://github.com/larsbx/biz-kit/issues/92),
[CoopSubstrate authority](2026-10-11-single-source-of-truth.md), and
[agent-neutral architecture](2026-10-24-signed-agent-runs.md).
