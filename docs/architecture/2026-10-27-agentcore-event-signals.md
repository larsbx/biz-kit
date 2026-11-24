# AgentCore event-driven orchestration — staging signal bridge

Date: 2026-10-27. Status: **opt-in, staging-only wakeup integration**, not a
production event subscriber or business-event writer.

## Design decision

**Events are the primary source of coordination intent; timers are safety nets.**

Biz-kit's signed `CoopSubstrate.Log` remains the *only* authority for
business and task facts. The existing append path authenticates signers,
checks admission and persists a canonical, hash-chained event before calling
`CoopSubstrate.Feed.publish/1`. Feed notifications use the already-existing
cluster-wide `:pg` group (`CoopSubstrate.Feed`, `:ledger`).

The new `AgentOpsStore.EventWakeup` subscribes **only in staging** to that
group and translates a notification into `TaskCore.ExecutionWorker.wake/1`.
The worker coalesces bursts and protects its existing one-shot timer against
multiple overlapping periodic scans. The notifier passes **no event payload,
principal, signature, tool result, or lease material** into the coordinator.

A wakeup triggers the already-existing `AgentOpsStore.Coordinator.tick/3`,
which obtains fresh committed TaskCore state, checks separate read/execute
permissions, resolves administrator-approved engine-neutral execution
profiles, then uses `AgentOpsStore.Postgres`'s transactional CAS to claim an
operational effect. A forged in-memory notification can only request this
recheck, never create a ledger fact or confer execution authority.

## Event and effect lifecycle

| Event or effect | Durable authority | Downstream interpretation |
| --- | --- | --- |
| `TaskAgentRunRequestedV1` | Signed CoopSubstrate log | Eligible run may be enqueued after current scoped-grant checks |
| `TaskAgentRunCancelledV1` | Signed CoopSubstrate log | Running effects must be fenced and backend termination requested |
| `TaskAccessRevokedV1`, principal offboarding, grant revocations, task lifecycle changes | Signed CoopSubstrate log | Wake up reconciliation; revoke/terminate effects as required by current replay |
| Operational claim, heartbeat, backend locator, retry/failure, candidate checksum | PostgreSQL `agent_ops` (same governed database) | Attempt supervision only; does not change business facts |
| Verified candidate and custody receipt | Existing artifact/custody gates | Still requires independent DoD review and signed acceptance |
| Federated ActivityPub or other external message | Untrusted transport until independently authenticated | May *propose* a command; must not bypass signed domain admission |

**Exactly-once side effects are not implied by message delivery.** Effect IDs
are derived from accepted run-intent event IDs and are subject to unique
database constraints and CAS fencing. Backend `launch/3` must honor the
same immutable effect ID and provide finality/absence observations. A crash
after external launch but before backend-handle storage must remain
ambiguous until separately verified reconciliation.

## Delivery guarantees and recovery

`:pg` notifications are **not durable**. They may be delayed, duplicated,
lost during node restart, or arrive while the worker is already busy.
They are an optimization to reduce normal response latency, **never** the
acknowledgment of task delivery. The existing periodic worker tick remains
enabled and re-reads the current ledger projection to discover every
signed run intent; its SQL registration is idempotent. If wakeups are lost,
that periodic replay resumes work without inventing event facts.

`EventWakeup` uses a bounded debounce timer; `ExecutionWorker.wake/1`
marks an active tick dirty and schedules at most one follow-up, rather
than multiplying polling timers for every `:pg` message.

This is an incremental latency optimization. Durable event delivery already
exists in EventStore: reuse a persistent named subscription to the canonical
`ledger` stream, with bounded buffering and the library's stored checkpoint.
Commit idempotent effect registrations BEFORE calling `EventStore.ack/2`.
If the process crashes between commit and ack, the library replays the event
and stable effect identities deduplicate it. Do not add an application cursor
or reimplement subscription catch-up. The staging adapter and acceptance are
described in [the corrected delivery note](2026-10-27-agentcore-cursor-recovery.md).

## Activation

A trusted staging supervisor explicitly starts an
`AgentOpsStore.Worker` instance, obtains its PID, then starts
`AgentOpsStore.EventWakeup` with that worker PID, an independently trusted
host module, and an optional debounce interval. Do not add it to production
application startup by default.

The notifier requires `host.environment() == :staging`; it joins the
existing `:pg` group started by `CoopSubstrate.Feed` and monitors its
worker. A failed subscription or dead worker fails closed. No additional
broker, agent framework, Podman/Docker socket, shared mutable agent volume,
or public HTTP endpoint is introduced.

Docker and Podman named volumes continue to hold PostgreSQL operational
state if selected. An engine-local volume is persistent storage, **not** an
event bus, a distributed lock, a business ledger, or a substitute for
database durability and backups.

## Remaining production acceptance

- Prove signed-ledger replay and cursor catch-up under concurrent appends,
  transient disconnections, restart and cluster partition.
- Add an authorized production-host implementation; ensure permission
  revocations are checked at launch, tool-use, renewal and result admission.
- Restrict notification-driven work to current tenant/project budgets and
  immutable profile capabilities, with rate-limited wakeups.
- Validate real backend idempotency/lookup, cancellation finality and proof
  custody; never mark a task done because a worker emitted success.
- Validate any ActivityPub/external event against sender signature, tenant,
  federation policy and replay constraints before creating a signed biz-kit
  command.
- Retain the existing signed ledger and single authoritative command path.

See [Issue #92](https://github.com/larsbx/biz-kit/issues/92),
[feed specification](2026-10-18-change-feed.md) and
[signed agent run model](2026-10-24-signed-agent-runs.md).
