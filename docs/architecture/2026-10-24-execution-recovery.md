# Staging execution recovery, tools and candidate custody

The signed CoopSubstrate ledger remains the sole business authority. This
change adds operational recovery and private candidate storage; it adds no
agent business writer, Definition-of-Done acceptance, production startup or
public HTTP endpoint. Target configuration and real local/hosted backend
connection work remain separate.

## Ownership

| Component | Responsibility |
| --- | --- |
| `TaskCore.ExecutionRecovery` | Generic, pure, effect/epoch/reference-bound recovery decisions |
| `TaskCore.ExecutionTools` | Generic independently authorized task-read projection; no writes |
| `TaskCore.ExecutionWorker` | Generic bounded monitored ticks, crash isolation and redacted status |
| `AgentCore.RecoveryPort` | Versioned execution-adapter lookup/capability contract |
| `AgentOpsStore.Coordinator` | Fresh signed run/grant/profile/consent checks around SQL and adapters |
| `AgentOpsStore.Postgres` | Database-clock CAS, bounded bytes, operational receipts and scoped retrieval |
| `AgentOpsStore.ToolProxy` | Typed host-authenticated execution-instance read access |
| `AgentOpsStore.Host` | Required trusted replay, identity, cleanup and proof-verification integration |

Framework, model, container and hardware settings stay in approved profiles.
No backend-specific field is added to signed task events. Existing
`AgentCore.Attempts` APIs remain compatibility primitives; new general recovery,
worker and task-read behavior lives in TaskCore.

## Durable state and crash cases

Apply SQL migrations 001, 002, then `003_recovery_custody.sql`, in order, to the
same governed database. Migration 003 adds an execution deadline, private
candidate bytes and backend observation receipts. It clamps claims/renewals
to one total duration budget; retries and ownership adoption do not reset it.

Repeated complete signed-replay scans reconstruct the outbox by stable effect
ID. A crash after external creation but before storing its handle is recovered
by the same effect ID. A verified running execution can be adopted under a
new generation and secret token; its launch count is unchanged. Unknown
outcomes remain leased. Expiry by itself never permits relaunch.

Only independently verified **final** absence can return an expired execution
to pending, within its original duration/attempt budget. Absence must cover
in-flight creation and the backend's permanent idempotency/tombstone contract;
404, empty enumeration, timeout or an unverified assertion is insufficient.
There are at most two launch attempts in this staging bridge, and each uses
the same immutable effect ID. Adoption does not consume another launch attempt.

Withdrawal fences a lease before requesting termination. An acknowledgement
remains `cancel_requested`. Only a verified final termination/absence observation
can confirm cancellation. Late candidates cannot bypass cancellation. SQL
version/epoch CAS and receipt-to-effect/generation binding reject competing
owners and receipt replay. Budget exhaustion requests termination.

## Host integration and proof boundary

`AgentOpsStore.Host` documents the required callbacks. `context/1` and
`committed_state/0` supply current committed signed replay. The host must
serialize sensitive disclosure/admission against revocation; a cached replay
or a check before a network wait is insufficient. This library does not claim
to solve a host's ledger/DB/disclosure atomicity window by interface alone.

`recovery_context/1` resolves the exact historical immutable profile through
separately authorized cleanup policy, including after run/profile revocation.
It grants no new execution/read permission. `request_termination/2` must resolve
the immutable effect/reference and invoke the approved adapter's cancellation
contract; it must not select another engine or run arbitrary commands.

`verify_observation/2` checks backend proof provenance, effect/reference identity,
generation binding and finality. It returns normalized host-only fields:
`effect_id`, `epoch`, `backend_ref`, `state`, `receipt`, `verified: true`; terminal
observations also require `final: true`. Candidate observations additionally
require bounded `candidate_bytes` and `within_budget: true`, after independently
verifying completion within `row.execution_deadline`. The normalized receipt
must bind that context and contain no credentials; at most 65,536 bytes persist.
The marker fields are verifier outputs, never assertions accepted from a tool
body. No permissive verifier is provided; missing/unavailable verifiers fail
closed. Real backend verifiers are still required before staging acceptance.

Adapters must implement launch/poll/cancel and lookup, and advertise
`idempotent_launch_v1`, `effect_lookup_v1`, `cancellation_v1` and
`bounded_results_v1`. Declaration plus callback presence is a prerequisite,
not proof that the backend enforces the contract.

## Tools and candidate storage

Transport handlers must use `ToolProxy.request/4`: credentials are authenticated
separately from request JSON through the host's execution authentication service.
Identity binds principal, effect, current generation and immutable backend
reference. `call/4` is internal for already authenticated host identities.

Only `task.read` with empty arguments exists. It requires an active unexpired
instance, fresh independent read/run grants, current task revision, approved
profile, consent and trusted `task_read_v1` feature selection. Its allowlist
excludes credentials, grants, evidence submissions and custody data. No generic
apply, shell, completion, business-write or candidate-submit tool exists.

Trusted runner result admission uses fresh authority and a host-only lease.
SQL stores bounded bytes, computed SHA-256 and an effect/epoch-bound custody
locator atomically before `candidate_ready`. The recovered-result path first
requires an independent on-time completion proof. Reads bind chapter, tenant,
project, task, task revision and source event, and verify the actual bytes/hash.
Candidate bytes remain untrusted, non-authoritative output in a private
operational table. They are NOT a signed `ArtifactCustodyRecordedV1` receipt,
accepted evidence or a domain mutation. Existing business review/append gates
must authorize any later promotion separately. Legacy digest-only rows do not
count as durable candidate custody.

## Opt-in worker

A staging host may explicitly add this supervised child after supplying the
trusted host callbacks and reviewed DB credentials:

```elixir
{AgentOpsStore.Worker,
 host: MyStagingExecutionHost,
 connection: host_postgrex_connection,
 owner: "staging-node-1"}
```

It scans durable effects, checks withdrawals and reconciles expired work.
Ticks are isolated in linked/monitored processes with a local timeout. Token
material and callback exceptions are not retained in worker status. Restart
uses database state; in-memory state never licenses relaunch. No child is
added to application startup automatically, and the bridge refuses production.

## Evidence and open gates

Deterministic tests cover unknown/duplicate outcomes, lost handles, stale owners,
cross-generation receipt replay, revoked grants, stale task versions, scope
isolation, bounded/tamper-checked custody, late candidates after cancellation,
timing attestations, worker termination and forbidden tools. SQL contract tests
use deliberate clock backdating rather than sleeps. Backend proofs in host
tests are explicitly synthetic fixtures and are not conformance evidence.

Native PostgreSQL 16 volume CI, full signed-ledger/umbrella checks, concrete
transport authentication, immutable registry/cleanup publication and verifier
implementations, and conformance with two distinct real execution backends
remain acceptance gates. There is no production cutover and issue #92 stays open.

## Local validation receipt

On 2026-10-24, pinned Elixir 1.19 / OTP 27 independent package checks passed
101 TaskCore tests and 25 AgentCore tests, with warnings-as-errors compilation.
The host/storage harness compiled against the repository's pinned Postgrex
0.22.4 and passed 11 tests (including integration-tagged cases) over a disposable
PGlite 0.5.11 PostgreSQL-compatible socket. All three migrations and all three
SQL contract scripts executed successfully in that embedded PostgreSQL runtime.
This is supplemental evidence, not native PostgreSQL 16 volume, multi-node or
real execution-backend conformance. The committed storage workflow runs the
same SQL contracts and host integration on native PostgreSQL 16.
