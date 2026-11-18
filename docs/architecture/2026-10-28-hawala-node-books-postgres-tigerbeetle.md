# Hawala node-owned books: TigerBeetle first, persistence afterward

Selected architecture: 2026-10-28. **Host integration contract; native adapters
and live financial execution are not activated.** This supersedes the
[PostgreSQL-first host proposal](2026-10-28-hawala-node-books-postgres-first-archived.md).
The canonical specification, core and opt-in native storage implementation remain owned
by `larsbx/hawala-core`, pinned independently in
[`hawala-tigerbeetle-first-pin.json`](fixtures/hawala-tigerbeetle-first-pin.json).

Storage implementation update, 2026-10-30:
[PostgreSQL event log and Redis consolidation](2026-10-30-postgres-event-log-redis-consolidation.md)
specifies staged replacement of the Elixir EventStore library behind Log.
References to EventStore below describe the active adapter and recorded
acceptance; the replacement must preserve signed admission and durable replay.
The financial commit order and all production gates remain in force.

## Financial commit and downstream copies

**Record securely in TigerBeetle first. Its confirmed complete linked operation
is the financial commit. Persist the outcome elsewhere afterward.**

The financial call MUST NOT require a per-operation PostgreSQL intent/journal
commit, SQL balance fold, EventStore append, SQL outbox insert, mirror verification
or destination acknowledgement before reporting native financial acceptance.
Authorization, registry provisioning and secure caller retention of original
IDs/evidence remain prerequisites, not extra server-side financial decisions.

| Component | Authority and persistence responsibility |
| --- | --- |
| Hawala financial gateway + TigerBeetle | Gateway verifies current signatures, consent, scope/policy and effective fencing; TigerBeetle decides native financial acceptance and balances |
| `CoopSubstrate.Log` / `CoopSubstrate.EventStore` | Signed business admission and history; append authenticated financial outcomes afterward under the existing gate |
| PostgreSQL projections and operational tables | Rebuildable financial reports, workflow state, destination receipts and cursors; never an independent spending authority |
| CDC / replay source | Transport complete native history to independent persistence workers; delivery is not a new financial commit |
| Executors / observers / attestors | Separate current permissions, original attempt, execution observations and settlement evidence |

EventStore is the logical Elixir EventStore backed by PostgreSQL. This does
not create two financial authorities or require two synchronous persistence
acknowledgements. Nonfinancial business facts keep their signed admission
path. The change is financial ownership and write order, not a bypass of Log.

## Host flow

1. Present the authorized operation to its scoped Hawala gateway using original
   stable operation/transfer IDs. No PostgreSQL-first financial append.
2. Gateway submits the complete native linked chain, including every required
   financial uniqueness/reservation guard. TigerBeetle acceptance is the commit.
3. Return the native financial outcome without waiting for downstream stores.
   Missing response means Held/Unknown, never permission for another payout ID.
4. Native replay/CDC consumers recover complete groups and independently persist
   signed business outcomes, SQL views and any additional destinations.
5. Business workflows advance only on the evidence their existing gates require.
   Financial acceptance alone does not establish execution or settlement.

The native persisted group identifies operation, epoch, total leg count and
each leg index; its first transfer ID is the permanent operation anchor. Linked
flags are checked against the pinned native version before normalization;
metadata IDs alone are not unique constraints. The immutable source profile defines the representation and
supported posted-transfer subset. Never infer a whole journal from one CDC leg.

Each destination owns a cursor for `(destination, cluster_id, generation)`.
Persist the whole derived bundle, source-ID/body binding, processed receipt and
cursor atomically in that destination where possible. Signed outcomes still
enter through Log and retain native provenance. If Log append and cursor cannot
share a transaction, source-bound idempotent admission MUST survive append-before-
cursor crashes before that adapter is accepted. Do not write unsigned rows
directly or give a projection permission to resubmit a financial command.

ACK only after destination durability. Exact replay is a no-op; changed body
under an original ID is conflict evidence. Source recovery must cover lost
notifications, missing broker messages, destination outages and backup restore.
Do not advance past incomplete groups or infer completeness from a maximum
timestamp. One destination can catch up while another is unavailable.

## Retained evidence, recovery and fencing

TB records only its fixed financial schema. Participant signatures, complete
terms and other business metadata must already exist durably with their evidence
owner, or be losslessly recoverable under a reviewed native encoding. A pointer
or hash cannot reconstruct missing bytes. Unsupported evidence/guard requirements
must refuse this fast path; do not hide a required PostgreSQL prewrite inside it.
Later host signatures attest the observed outcome, not the participant's consent.

Uncertain submissions use lookup and identical retry of original IDs/payloads.
An absent lookup after session interruption is not a terminal rejection because
the original request may still commit. Partial or conflicting groups hold the
affected scope. A stale PostgreSQL copy never overwrites newer TB balances.
Ordinary mirror lag does not hold unrelated financial admission; declared
capacity/evidence-retention constraints may apply scoped backpressure.

Each independently governed installation keeps its own authoritative books and
retained copies. Replica operators belong inside the same trust domain. One
effective authority owns each declared scope/lot/collateral allocation; federation,
read-only copies and CDC consumers confer no additional spending power.
The actual gateway/native access and external execution boundary must fence old
writers on authority succession. Cross-authority prepared holds and recovery
retain the existing coordinator contract, not cross-store or cross-cluster ACID.

## Existing proof work and actual delivery boundary

The accepted EventStore candidate-bundle/cursor proofs and staging signed replay
remain valid within their stated assumptions. They do not prove TB acceptance,
native guard-account semantics, CDC completeness or the signed outcome adapter.
Financial reconciliation compares complete inventory, counters, registry/compiler
context and the same native checkpoint; equal net balances are insufficient.

The canonical `hawala-tigerbeetle-flow` core provides tested submission/recovery
and independent sink-draining ports. Its bounded decoder and concrete
`replay::HistorySource` implement complete-group recovery over a trusted paged
native-history port. They preserve partial suffixes, reject unsupported native
modes, bind cluster/generation and restart from each destination's durable cursor
without skipping read-ahead records. No financial command is re-emitted by replay.

The abstract finite model exhausts 100 states in Quint/TLC, with 1700 certificate
edges checked against Quint and the Rust core harness. Four unsafe model steps
and six Rust mutations produce their intended failures. New Lean sources and
an exact exporter comparison are wired into CI; local Lean failed before
elaboration on sandbox process-path access. This is not yet Lean acceptance or
a universal native-storage refinement. Synthetic ports supply authentication,
complete source coverage and durable sink behavior in these conformance tests.

The expanded immutable source pin includes the decoder, model, certificate,
generator and gates. It verifies exact source bytes, not runtime conformance.
The opt-in native increment now supplies the official pinned SDK adapter,
retained signed TEST evidence, deterministic compiler verification and an
independent signed SQLite WAL/FULL archive with atomic outcome/cursor commits.
Eight local storage/accounting/wire checks and four unsafe controls pass; the
new storage model exhausts 18 states. The three actual-service recovery tests
compile but local TB startup fails on denied io_uring. Native CI and Lean kernel
acceptance remain mandatory. Authenticated production range completeness, real
Log outcome admission, nonce/lot guards, effective fencing, cross-writer IDs and
concrete storage refinement remain open. No existing business writer or staging
consumer is silently promoted into a financial authority by this document.

The existing paired ADR N1–N7, D1–D6, G1–G11 and cross-authority proof pin remain
unchanged. The independent TB-first source pin avoids changing their acceptance
status or interfering with separately pending gap/status updates.


## Native increment and host admission gate

Hawala [#55](https://github.com/larsbx/hawala-core/pull/55), stacked on #54,
is pinned by exact source bytes. Its loopback-only adapter checks a complete
linked request, every original native ID, native flags and timestamp sequence,
and retained signed node-scoped admission. It never treats an unchecked native
status as complete acceptance. Full registry bytes and independently specified
posting pairs from #50 are checked; SQL-first checkpoint authority is excluded.
The signature domain explicitly says TEST and cannot stand in for production
participant consent. No production financial writer is enabled here.

This host does not append the native archive directly into EventStore. The
required next adapter must verify source context and original evidence, preserve
the complete operation, register the business outcome envelope and call
`CoopSubstrate.Log.append/2` or `append_if/3`. SQL inserts into EventStore bypass
business admission and are inadmissible. A source-bound idempotency key must
resolve an append-before-cursor crash without a duplicate business outcome.
This bridge remains unconnected; financial commit remains TB even while this
host's destination is unavailable. Native accounting evidence does not authorize
execution or settlement.

The native history reader trusts its isolated loopback server/OS and unfiltered
SDK query semantics. Retained signatures authenticate financial bodies; they do
not detect a malicious transport omitting an entire operation. Stronger native
transport authentication, completeness and external anti-rollback checkpoints
remain release gates. Separate destination databases/cursors can catch up without
reissuing a financial command, and no outcome archive gains spending authority.

Dependency order: accept #54, then the exact native/formal/workspace head of #55;
accept #195 and then this host pin only after their canonical dependencies. Drafts
with queued gates are not accepted changes. Do not merge the conflicting #50
profile wholesale or infer production readiness from integration conformance.


## Acceptance repair, 2026-10-29

The native service and workspace gates now pass in hosted CI at Hawala
`3db9d01f9ba7cf70ff5f9dee65c7989c49bbc9b4`. The independent host storage gate
also passes at biz-kit `a869b4a72f69fb1e901edb221d71d5ced15a16a0`.
The new storage Lean model compiled, but the aggregate Lean build failed on two
independent-destination proofs in `TigerBeetleFirst`. The revised canonical pin
contains their direct conditional-case proofs; full kernel build and exact
exporter regeneration remain required at the new head.

The parent host branch now incorporates accepted main changes, including the
correct native exchange result shape and the existing observer/attestor pins.
The full Dispatch integration job initializes its signed EventStore/Records
schemas before running device-enrolment tests, matching the established mobile
acceptance setup. This prepares test storage only; runtime financial, execution
and settlement release gates remain in force. Authenticated production source
completeness and actual idempotent EventStore outcome admission remain open.
