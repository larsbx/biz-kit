# Proof-to-runtime bridge: signed EventStore replay (staging only)

Date: 2026-10-27. Status: **proposed opt-in staging reader**, not enabled
in production. Signed business events continue to be admitted solely
through `CoopSubstrate.Log`, backed by the canonical EventStore stream
`ledger`. No new canonical event store, orchestration writer or agent
executor is introduced.

## Concrete modules

- `CoopSubstrate.SignedConsumerSource`: captures the current
  `Log.head().global_seq`, then calls `Log.verify_chains(as_of: head)`,
  auditing signature sets, canonical encoding and *both* hash chains up
  to the captured position. Only after that succeeds does it allow a
  bounded `Log.read_all(from: next, as_of: captured_head)` page. The
  full-record `Envelope.event_hash/1` is the committed record digest.
- `AgentOpsStore.EventReplay`: accepts **only a host declared as staging**
  and its trusted `event_consumer_context/0` (home ID, consumer ID,
  signed source and reviewed explicit no-op list). It reads the durable
  operational `EventCursor.watermark/3`, captures a verified ledger
  head, validates one bounded page for exact contiguous sequence, maps
  each accepted event via `EventEffects.derive/2`, and registers its
  complete operational bundle via `EventCursor.commit/2`.
- `EventCursor.commit/2`: one PostgreSQL transaction per event writes
  all effect IDs (or none), a durable processed receipt, then advances
  the watermark under a row lock and contiguous-sequence guard.
  Only candidate metadata is written; no execution authority is granted.

## Failure semantics

| Failure | Required response |
| --- | --- |
| Invalid/unverifiable canonical prefix | Refuse before any consumer cursor advancement |
| Missing, duplicated or reordered page event | Refuse before SQL on that page |
| Unknown/unreviewed event type | Halt at that position; earlier committed checkpoint may remain durable |
| Missing required effect, duplicate effect-ID across positions | SQL exception rolls back current receipt, effects and cursor |
| Crash after one committed event but before next | Restart reads only from last durable watermark; no effect is executed by replay |
| Lost/forged `:pg` notification | No authority change; next periodic bounded replay recovers from cursor |
| Concurrent consumer | Row lock and contiguous CAS allow one durable version at a time |
| Separate business home | Home+consumer-scoped SQL cursors, never a federation-global cursor |

The integration tests use an explicitly **synthetic, non-signature-proving**
source for controlled failure injection. A *separate* CoopSubstrate test
exercises the real signed append path, prefix verification, immutable event
hash and one/two-event bounded reads. Neither fixture is evidence of a
deployed or generally available event-consumer daemon.

## Trust and operational limits

**Important:** `CoopSubstrate.Log.read_all/1` decodes records but does
not independently rerun `Envelope.verify/1` or audit global/per-stream
links on every normal read. That is why the source explicitly audits
`verify_chains` before reading the captured prefix. A successful audit
does not replace externally retained checkpoints or prevent a privileged
database rewrite *between* audit and read. The production security model
must cover storage administrator trust, checkpoint anchoring and audited
backup/restore. A future incremental verifier can optimize replay only
if it preserves the same cryptographic guarantees.

Full-prefix verification is O(history) for every replay invocation and
may be too expensive at scale. This is a deliberately conservative
staging acceptance bridge, not a throughput-optimized production
deployment. No production subscription loop has been installed.

The `ignored_types` policy is **reviewed host configuration**, not a
customer/agent-provided list. New event types stop processing until a
reviewed mapping or durable no-op determination exists. A genuine
`TaskAgentRunRequestedV1` produces only an operational candidate;
current task version, DoD, read and execution grants, consent, principal
status, profile, data disclosure and backend recovery must be checked
again by the coordinator immediately before launch, tools, renewal and
result admission.

## Proof correspondence and remaining gates

1. **Lean/Quint**: `formal/lean/BizKitBundles.lean` proves the abstract
   atomic prefix invariant; `formal/quint/cursor_transaction.qnt` models
   crash rollback and a no-effect receipt. These proofs are not yet
   accepted in CI: repair PR #168 remains open.
2. **SQL**: `004_event_cursor.sql` stores complete operational bundles
   and the contiguous watermark. PR #169 corrects a real test-contract
   mismatch and remains pending hosted PostgreSQL acceptance.
3. **Replay**: bounded source snapshot + sequence validation +
   `EventCursor.commit/2` corresponds to the abstract `commitNext`
   transition, but the real Elixir/SQL refinement still requires exact-head
   hosted, crash and concurrency acceptance.
4. **Release**: do not activate agent workers, remove old writers, or
   merge federation business authority on the basis of this staging bridge.
   Later operational consumers can use :pg notifications only as a wakeup
   and must retain durable replay. Actual cross-node, independent-host,
   revocation and recovery checks remain in [#161](https://github.com/larsbx/biz-kit/issues/161).

No cross-installation global ledger is created: each independently
administered ActivityPub home keeps its own signed EventStore authority.
