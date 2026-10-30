# PostgreSQL event log, Redis operations and TigerBeetle financial commit

Date: 2026-10-30 (America/New_York).
Status: **Selected target specification; implementation and production cutover gated.**

Companion: [hawala-core ADR 0007](https://github.com/larsbx/hawala-core/blob/main/docs/decisions/0007-storage-roles-postgres-event-log-redis.md).

## Context and scope

The current Elixir EventStore already uses PostgreSQL. This decision targets
replacement of the `eventstore` library behind `CoopSubstrate.Log`, not a move
from a separate EventStore database engine. The existing backend remains the
active implementation until the replacement passes the acceptance below.
A merged ADR is not evidence of migration, runtime conformance or deployment.

This updates the backend-retention direction in
[one source of truth](2026-10-11-single-source-of-truth.md), while preserving
its single signed business history and command admission path. It supplements
the [TigerBeetle-first host contract](2026-10-28-hawala-node-books-postgres-tigerbeetle.md).
The frozen [substrate protocol](../../apps/coop_substrate/SUBSTRATE.md),
current signed authorization and financial release gates continue to apply.

## Decision: storage responsibilities

| Component | Responsibility | Forbidden authority |
| --- | --- | --- |
| Hawala gateway and TigerBeetle | Verify current financial authorization/evidence/fencing; native acceptance and balances for a declared financial scope | Neither SQL nor Redis may independently authorize another spend |
| PostgreSQL business event log behind `CoopSubstrate.Log` | Canonical signed nonfinancial business history; subsequent authenticated financial outcomes | A business outcome does not establish payout, execution or settlement |
| PostgreSQL operational tables and projections | Orders/workflow metadata as governed by their domain, consumer receipts, effect claims, cursors and rebuildable reports | Stale reports do not license commands or overwrite TB balances |
| Redis | Streams work delivery, delayed/retry scheduling, throttling, presence, shared caches and live projections | No financial commit, permanent replay consumption, current permission, custody proof or external-effect authority |

The financial call MUST NOT wait for a PostgreSQL intent/journal, business-log
append, SQL outbox, Redis write or downstream acknowledgement before reporting
confirmed complete TigerBeetle acceptance. Original IDs and full required
evidence remain durably retained by their designated owner before submission.
A digest or pointer cannot reconstruct missing evidence. Unknown financial
outcomes retain the original IDs; replay never submits a new financial command.

Nonfinancial commands still require durable signed admission. Preserve
`append/2`, `append_if/3`, reads, verification and checkpoint behavior at the
Log boundary; direct SQL writes by callers cannot bypass that gate.
PostgreSQL is not a new competing business writer.

## Required PostgreSQL log contract

1. Store the exact full `CoopEventCanonicalV1` record bytes in `bytea`.
   Preserve original event IDs, signatures, schema/profile versions, hashes,
   global/per-stream sequences, and external checkpoint verification.
   Query columns/indexes are derived; JSON reserialization is not canonical storage.
2. Verify structure, registered types, complete valid signatures, scopes and
   current admission preconditions before committing. Guard evaluation and
   acceptance must observe one consistent committed head. A concurrent writer
   or stale appender loses an expected-head compare-and-swap and recovers;
   no Redis lease can authorize an append.
3. Commit each admitted batch, canonical head/chain changes and required
   identity bindings atomically. A failed member or stale head leaves no
   accepted prefix of that batch. Preserve the existing single ordered ledger
   per independently governed home. Do not silently shard or renumber it.
4. Bind permanent source/operation IDs to immutable admitted content, separately
   from any newly assigned log position. Identical retry returns the original
   result; changed content under the same ID is retained conflict evidence.
   Transient Redis keys cannot implement permanent idempotency.
5. Provide bounded keyset replay through a fixed verified head and derived
   stream reads. Cursors denote complete committed prefixes. SQL sequence
   allocation, timestamps and maximum observed IDs alone do not prove a prefix:
   allocation and transaction commit can occur in different orders.
6. Persist the complete consumer candidate/effect bundle, explicit processed
   receipt (including reviewed no-op), immutable source binding and cursor in
   one transaction where co-located. Unknown event types halt that consumer.
   Retain current sequence-gap refusal and home/consumer isolation.
7. If signed outcome admission and a destination cursor cannot share a real
   transaction, use source-bound idempotent Log admission and demonstrate
   append-before-cursor recovery. Merely nesting calls to separate connection
   pools inside `Repo.transaction` gives no shared rollback.
8. Acknowledge work only after durable destination completion. Preserve stable
   effect IDs, current authorization checks and external-provider lookup or
   fencing across retries. An operational candidate or claim is not an
   executed effect. Exactly-once external execution is not supplied by SQL ACID.
9. Restrict application roles to reviewed append and operational interfaces;
   deny ordinary mutation/deletion of accepted history. Independently retained
   signed checkpoints detect privileged rewrite/rollback; database permissions
   alone do not establish cryptographic immutability.
10. Keep head-lock work short and indexed; perform no remote/provider calls
    inside the append transaction. In particular, redesign any existing
    `Log.federation_effect` provider call under the ledger lock using durable
    intent and an execution fence that preserves its current authorization
    race guarantees before moving that path. Preserve required canonical
    serialization; removing it requires a separate protocol decision and proof.

## Redis consolidation and removal targets

One shared scheduler/worker contract replaces covered Oban/AshOban jobs,
custom retry timers and overlapping queue implementations. Use Streams consumer
groups for delivery/reclaim and sorted sets for due work; atomically claim due
items before dispatch. The scheduler must cover retry/backoff, recurring jobs,
cancellation, per-scope concurrency, reclaim and failed-work inspection/recovery.
Expiring leases are coordination hints; durable effect admission and fencing
remain at the owning authority.

Durable business intent and delivery receipts must reconstruct outstanding
work after Redis loss, lost SQL-to-Redis publication, trimming or failover.
Use a durable source scan/reconciliation path as well as wakeups. Redis and
PostgreSQL `NOTIFY` are not the sole record of work. Control bounded retention
and recovery load; a broker ACK is not an application effect receipt.

| Removal target | Required cutover before deletion |
| --- | --- |
| Eatsbot's five imported apps and SpruceGoose runtime | Salvage retained rules and capabilities, preserve required history/IDs, move clients, fence old writers, then remove hosting/auth/extensions/releases |
| Oban/AshOban | Migrate every retained job to the accepted Redis contract, then remove workers, supervisors, cron/pruner config, flags and dependencies |
| Covered Kafka notification paths | Inventory consumers, migrate/reconcile their backlog and delivery obligations, then remove wrappers, notifier hooks and broker responsibility for those paths |
| Custom transient singletons/ETS keepers and sweepers | Replace covered cross-service state with bounded expiring Redis data; retain local state only where it serves a measured local purpose |
| Federation storage machinery | Move durable discovery/delivery facts to ordinary durable storage and derive Redis indexes; preserve tombstones, blocks, generations and provenance |
| Repeated polling and full-map scans | Use bounded SQL reads, shared versioned projections and coalesced invalidations |
| Packaging/CI/prototype/document duplication | Consolidate unnecessary boundaries and repeated setup; remove unwired production compilation; retain one current contract and dated history |

These are migration/removal obligations, not a statement that current services
or dependencies have already been retired. Authentication/revocation, financial
nonces, SQL mutation idempotency, reservations and effect admission do not become
expiring caches. Redis operates within each installation's trust boundary.

## Surviving SQL priorities and evidence

| Path | Required change / diagnostic |
| --- | --- |
| Dispatch audit append | Check tenant/latest-event index and query plan; narrow head reads and measure lock wait/hold duration |
| Participant status | Batch latest-per-participant reads and validate tenant/participant/time indexing |
| Boards and trips | Bound/page reads; filter closed/history work in SQL; publish source version and freshness |
| Location batch admission | Prefetch devices, grants and duplicates; retain admission-time consent/revocation correctness |
| Identity and consent | Match indexes to actual lookup keys; remove per-row role/grant queries without caching away revocation |
| Delivery and retention | Remove normal idle SQL polling once recovery scans exist; batch durable bookkeeping and schedule bounded idempotency cleanup |

These priorities are source-derived candidates. Before claiming a performance
gain, retain baseline and post-change query counts, `EXPLAIN (ANALYZE, BUFFERS)`
on representative safe workloads, latency distribution, lock waits and recovery
cost. Evaluate indexes against actual predicates and ordering. Do not solve
existing contention by introducing a new universal event/worker lock.
PostGIS, business metadata, durable authorization/effect records and offline
client custody retain their distinct purposes.

## Consequences and rejected alternatives

Direct PostgreSQL can reduce dependency/configuration overhead and permit
explicit local transactions and workload-specific indexes. It uses the same
storage engine as today's EventStore, so no automatic throughput gain is claimed.
EventStore already offers expected-version checks, persistent subscriptions and
transaction participation; replacement is not required solely for those features.

The cost is owning their relevant semantics, compatibility, migrations and
recovery tests. Keep the library until the narrower replacement demonstrably
preserves them. Do not recreate a general event-sourcing framework, drop signed
history into mutable business rows, or replace durable replay with Redis-only
delivery. Consolidating schemas/pools is not an independent disaster-recovery
copy; retain the explicitly required independent evidence destinations/backups.

## Acceptance and migration

| Gate | Required evidence before cutover |
| --- | --- |
| P1: compatibility | Existing signed append/read/guard/chain/checkpoint suites pass against the new adapter; byte-for-byte history and export comparison |
| P2: concurrency | Independent writers race the same head; stale guard, revoked grant, duplicate ID and changed-body attempts refuse correctly; failed batch leaves no partial state |
| P3: replay | Transaction allocation/commit reordering, gaps, complete/no-op bundles, cursor races and unknown types preserve a complete prefix |
| P4: crashes and storage | Fault injection before/after append, bundle commit, cursor update and ACK; restart and stale-backup recovery under the declared PostgreSQL durability/failover profile |
| P5: Redis loss | Flush/restart Redis and drop/duplicate/reorder wakeups; rebuild work and views without changed financial outcomes or duplicate external effects |
| P6: financial bridge | Complete native groups retain cluster/generation and original evidence; append-before-cursor retry is idempotent; downstream outage never triggers reposting |
| P7: performance | Bounded reads and catch-up, measured query/lock changes, backlog recovery and explicit capacity limits |
| P8: formal and cutover | Map actual SQL/Elixir transitions to existing models, run exact-revision Lean/Quint and integration checks, verify history at an anchored head, fence old writers and publish the rollback boundary |

Existing [formal acceptance](2026-10-28-eventstore-formal-acceptance.md) and
[signed replay acceptance](2026-10-28-eventstore-signed-replay-acceptance.md)
remain evidence for their recorded implementation only. They do not certify
the replacement adapter. Update refinement and mutation controls rather than
waiving or silently carrying over implementation-specific proof claims.

Implementation order: fix surviving SQL query shapes; implement the narrow log
adapter and shared Redis worker contract; verify compatibility/recovery; migrate
capabilities and delivery consumers; fence old writers and cut over at a verified
head; remove covered EventStore/Oban/Kafka/legacy dependencies and configuration.
Temporary comparisons have an explicit retirement condition. After new writes,
rollback must retain the entire verified new prefix and fence the replacement;
never switch back to a stale legacy database.

## References

- [Elixir EventStore API](https://eventstore.hexdocs.pm/EventStore.html):
  PostgreSQL backend, expected versions, persistent checkpoints and shared-connection transaction support.
- [PostgreSQL NOTIFY](https://www.postgresql.org/docs/18/sql-notify.html):
  transaction-bound notifications to listeners, not retained event history.
- [Redis Streams](https://redis.io/docs/latest/develop/data-types/streams/):
  delivery and consumer-group primitives, not financial authority.
