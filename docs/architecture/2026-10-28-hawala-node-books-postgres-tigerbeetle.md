# Hawala node-owned books: TigerBeetle first, persistence afterward

Selected architecture: 2026-10-28. **Host integration contract; native adapters
and live financial execution are not activated.** This supersedes the
[PostgreSQL-first host proposal](2026-10-28-hawala-node-books-postgres-first-archived.md).
The canonical specification and port-level Rust implementation remain owned
by `larsbx/hawala-core`, pinned independently in
[`hawala-tigerbeetle-first-pin.json`](fixtures/hawala-tigerbeetle-first-pin.json).

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
flags are not retained by TigerBeetle and metadata IDs alone are not unique
constraints. The immutable source profile defines the representation and
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
and independent sink-draining ports. The pin check verifies exact source bytes;
it is not runtime conformance. Real TB SDK/server integration, complete native
replay, signed source-bound outcome admission, transactional durable sinks,
nonce/lot races, multi-process crash tests, effective fencing and formal storage
refinement remain implementation work. No existing business writer or staging
consumer is silently promoted into a financial authority by this document.

The existing paired ADR N1–N7, D1–D6, G1–G11 and cross-authority proof pin remain
unchanged. The independent TB-first source pin avoids changing their acceptance
status or interfering with separately pending gap/status updates.
