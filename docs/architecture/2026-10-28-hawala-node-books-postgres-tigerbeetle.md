# Hawala node-owned books: PostgreSQL commit and verified TigerBeetle copy

Date: 2026-10-28. Status: **Proposed host implementation contract**.
Documentation integration only; no financial writer, projector, execution
capability or production deployment is enabled.

Canonical source: hawala-core [PR #45](https://github.com/larsbx/hawala-core/pull/45),
merged as `671c3e0ce8af42888bc397f5a80ba4d529c1efc8`. The exact
[node-books specification](https://github.com/larsbx/hawala-core/blob/50a9c2ace013c28b4a55328e4f1ab8af4592f10a/docs/NODE_BOOKS_TIGERBEETLE_SPEC.md)
is pinned at source commit `50a9c2ace013c28b4a55328e4f1ab8af4592f10a`,
file SHA-256 `89a76509ed2fb06257660878ecdf38fe01a799c0183c065808802cef183de7da`.
Hawala owns this financial profile; this record maps its requirements to the
biz-kit host and acceptance work without copying its financial implementation.

## Integrated storage and authority contract

Each independently administered installation retains its signed history,
PostgreSQL journal/projections and TigerBeetle accounting data. One effective
financial authority orders each declared scope, lot and collateral allocation,
subject to all six [D5 gates](2026-10-28-hawala-shared-identity-and-scoped-authority.md).
A node without that mandate retains attributed evidence and read-only mirrors.

The selected profile is **one canonical PostgreSQL financial commit, then
mandatory TigerBeetle verification before execution**. PostgreSQL backs the
existing signed history and its atomic reference financial fold. TigerBeetle
is a required verified accounting copy, with one fenced projector. It does
not independently admit financial facts or join the PostgreSQL transaction.

TigerBeetle replicas belong to one declared installation/authority trust
domain, with local retention and declared failure domains. Independently
governed businesses do not become replicas or co-writers of a universal book.
Separate legal books retain separate accounting entries and authority.

| Boundary | Required host behavior | Current acceptance boundary |
| --- | --- | --- |
| Canonical admission | In one fenced, serialized PostgreSQL transaction: recheck signatures, mandate/epoch, grants, quote, expiry and custody; consume nonce/IDs; apply reservations, balanced reference postings and owned decisions; append exact signed bytes; allocate permanent accounting IDs and projection work | Existing Log batches alone do not demonstrate that all these financial writes share that transaction |
| Financial intent receipt | Return only after durable canonical commit, explicitly accounting-pending and non-executable until verified | Business append, operational receipt or transport acknowledgment is insufficient |
| Accounting projection | Read accepted financial events in source order; persist deterministic request bytes and original IDs; submit each complete journal as one linked transfer chain | A replay cursor does not prove TigerBeetle accepted the complete journal |
| Independent verification | Compare the same source checkpoint K, authority epoch, reference fold, registry/compiler digests and cluster generation; verify exact inventory, transfers, counters and balances | Delivery, CDC arrival, `exists`, current balances at a different prefix or a projection watermark is insufficient |
| Execution release | Recheck current epoch, mandate and unresolved disputes in the serialized gate; require verification through the original committed intent; durably release only the original attempt-bound capability | No current EventReplay result or candidate row releases financial execution |
| External observation/finality | Retain authenticated execution observations, settlement evidence and original encumbrances under Hawala's distinct authorities | Accounting verification does not establish cash movement, delivery or settlement |

The initial profile allows **at most one unverified committed financial event
per scope**. Admission rechecks that the accounting copy matches the current
financial head before accepting the next event. Missing, unavailable,
diverged or recovery-required accounting state holds the affected financial
scope. Committed intents remain committed and reserved while projection
catches up. Unrelated nonfinancial business events and healthy scopes continue.

## Relationship to the accepted EventStore work

The [formal acceptance record](2026-10-28-eventstore-formal-acceptance.md)
and [direct signed-replay harness](2026-10-28-eventstore-signed-replay-acceptance.md)
describe the abstract prefix/bundle proofs, staging operational cursor and
added direct test harness. Exact-head native execution of the new harness
remains a separate CI acceptance requirement.
`EventCursor` atomically writes a complete supplied candidate bundle,
processed receipt and watermark. It does not consume financial nonces,
reserve custody, post reference journals, compare TigerBeetle state or
authorize execution. Those proofs and tests cannot discharge D5 by themselves.

In particular, placing financial tables in the same database does not prove
transaction participation. The financial adapter must demonstrate that the
actual signed append and **all** required reference financial writes commit
or roll back together through the existing authority gate. Sequential calls
on separate transactions, an after-append consumer, or a second financial
append service cannot substitute for that requirement.

A generic global replay watermark and an authority scope's verified financial
head are distinct facts. Verification must bind the canonical source
sequence/hash and the exact scoped financial projection; it cannot infer
accounting completion from a count of consumed business events. ActivityPub
notifications, `:pg` wakeups and peer arrival order remain non-authoritative.

## Compiler, verification and recovery requirements

Use the canonical profile's exact integer range, currency/scale registry,
rounding, distinct-account postings and permanent injective mapping from
full canonical IDs to valid TigerBeetle IDs. Never truncate identity hashes,
split one journal across independent requests, accept arbitrary opening
balances or silently change compiler/registry versions. Publish canonical
bytes and differential vectors before accepting an adapter.

A verification record binds authority, scope, epoch, source sequence/hash,
journal digest, registry/compiler digests, accounting cluster ID/generation,
state digest, verifier and prior verification record. Its exact signing bytes,
domain and signer mandate remain implementation gates. It attests a checked
accounting copy, not assets or native TigerBeetle financial authorization.

After uncertain submission, look up and compare the **original** IDs and
payloads, then retry identically where allowed. No new payout ID, timeout
release or automatic canonical rollback is permitted. Extra accounting
mutations, conflicting payloads, missing history or uncertain restore retain
evidence and enter HOLD. A rebuild uses a new cluster generation, exact
replay, full verification and an effective fenced cutover. Epoch succession
must fence actual PostgreSQL writers, projector access and custody/execution
adapters; incrementing a local epoch number is insufficient.

Cross-authority obligations keep each party's books separate and follow the
canonical bilateral coordination contract. Prepared reservations remain
held during partition or coordinator failure. Replication and local commit
do not establish a peer's commit, a coordinator mandate or cross-store ACID.

## Ordered implementation and acceptance

1. Pin the actual server/client/deployment versions, scope and authority
   manifest; publish registry, compiler, verification-record and export bytes.
2. Implement the canonical pure accounting compiler in its Hawala-owned
   location; run exact money/range, multi-debit/credit, multi-currency,
   deterministic ID, capacity and changed-body replay vectors.
3. Refine the actual PostgreSQL financial append adapter: independent
   concurrent sessions, nonce/lot races, full rollback, crash after durable
   commit, receipt withholding and historical replay.
4. Run a real pinned TigerBeetle process through linked-journal failures,
   lost replies, original-ID recovery, inventory divergence, stale restores,
   projector fencing and complete cluster rebuild. Synthetic copies do not
   establish this boundary.
5. Extend Lean/Quint with canonical-prefix, accounting-prefix and execution
   gating, including two financial authorities and a distinct coordinator.
   Require the specified unsafe mutations to produce real counterexamples,
   and replay generated traces against both real storage adapters.
6. Review the host/profile integration in lockstep with Hawala before claiming
   interoperability. Retain independent custody, security/legal/operator,
   deployment, old-writer fencing and production release gates.

The mirrored D1–D6, N1–N7 and G1–G11 texts and existing cross-authority source
pin remain unchanged. This supplemental profile closes none of those gaps.
