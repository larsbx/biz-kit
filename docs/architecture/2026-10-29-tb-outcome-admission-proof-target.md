# TigerBeetle outcome admission: proof target

This follows accepted Hawala #54/#56 and biz-kit #195. It defines the next
host admission contract. It does not connect a financial writer, native replay
worker or EventStore outcome adapter. Existing Log admission remains unchanged.

## Key and evidence boundary

An admission slot is `(home, destination, cluster, generation, original operation
anchor)`. The anchor is the first original transfer ID of the complete native
operation. A replay position is an ordinal in a verified complete-group history;
it is not a transfer ID or native timestamp, and need not equal either one.
The `Source.anchor` mapping keeps these concepts separate. Including destination
allows independent durable sinks; it does not license different financial books.
Two installations with equal numeric IDs still have distinct admission slots.
The receiving Log fixes its configured destination identity; callers cannot
choose aliases for one Log to bypass its source-slot uniqueness boundary.

`Source` is an immutable snapshot supplied by the trusted native verification
boundary. Its `verified` premise means complete original evidence, canonical
outcome bytes and accepted native context have already been checked. Neither
model proves signatures, native range completeness, unique enumeration, snapshot
succession or the construction of that predicate. It cannot be populated from
an unauthenticated notification or an arbitrary caller Boolean in production.

Body tokens model exact canonical bytes by equality; they do not assume a hash
is injective. Runtime admission must retain and compare the complete original
outcome, including source context and native range. A new envelope ID, signer,
signature or timestamp must not create another business outcome on retry.

## Durable transitions and proved target

1. A serialized admission checks the source evidence and exact body. If the
   original slot is absent, it atomically appends the signed business outcome
   and establishes the binding recoverable from that accepted Log event.
2. An occupied slot is never appended again. The runtime returns the original
   accepted receipt on an exact retry and a conflict on changed bytes; the model
   proves these calls do not change durable state, not their wire response.
3. Cursor advancement is a separate transition. It requires the next complete
   group's exact accepted binding; it cannot skip an unaccepted predecessor.
   Admission can be out of order without advancing a gapful cursor.
4. A crash, lost reply, or restart retains durable Log facts. After an append
   before cursor commit, a retry reuses that binding; no second append occurs.

`BizKitOutcomeAdmission.lean` proves safety for arbitrary reachable histories:
every stored body has verified source provenance and exactly one append; empty
slots have zero appends; every cursor covers only a complete accepted prefix.
It separately proves exact retry and lost-reply retry stuttering, changed-body
refusal, unverified-input refusal, independent destination records and cursors,
and the separation between admission and checkpoint writes. The Source snapshot
is fixed throughout each theorem. Live source extension is a later obligation.

`tb_outcome_admission.qnt` checks two operations across five scopes. Each of the
four namespace coordinates varies independently from a base scope; all scopes
deliberately share numeric original anchors. Tests cover lost replies, changed
bodies, unverified evidence and out-of-order admission. Nonvacuity witnesses
require append-before-cursor, an out-of-order record and independently caught-up
destinations. Four negative controls must expose actual invariant violations:
duplicate append, body overwrite, cursor-first advancement and forgotten binding.

Both sources enter the existing complete Lean/Quint acceptance lane. The new
Lean library receives its own fresh kernel replay and module-scoped axiom audit
under the unchanged allowed axioms. These are abstract proofs and finite checks,
not a refinement proof for arbitrary SQL or Elixir implementations.

## Required implementation correspondence

| Model item | Runtime obligation before accepting the bridge |
| --- | --- |
| Verified snapshot and `anchor` | Read complete authenticated original native groups; retain source ordinal/range and stable original anchor; reject incomplete, conflicting or wrong-context history |
| `recordOutcome` + recovered binding | Register the outcome envelope/schema and signed validity rules; deduplicate by full source slot inside the serialized `CoopSubstrate.Log` admission; rebuild bindings by audited replay |
| One `appends` increment | Persist binding with the canonical signed event, or derive it entirely from that event; a separate operational table written after append cannot supply this guarantee |
| Exact retry / conflict | Compare retained exact source outcome bytes and recover the original accepted receipt, even when a delivery envelope has a different retry ID |
| `checkpoint` | Update only that destination's complete-prefix cursor after confirmed durable Log admission; retry unknown replies using the same source identity |
| `crash` | Kill the appender after durable append and before reply/cursor; recover through actual EventStore and verify exactly one accepted outcome and the original receipt |
| Scope isolation | Race two workers; vary home, destination, cluster and generation independently; test copied numeric anchors and altered bytes |

Use `Log.append/2` or `append_if/3` after the source-bound duplicate and validity
rules are installed in the appender. Do not insert directly into EventStore or
trust a prior external lookup as an atomic admission decision. A process-local
cache alone is insufficient. A stale appender must still lose the existing
expected-version race and rebuild from accepted history before retry.

Financial commit stays in TigerBeetle. EventStore admission records an already
confirmed outcome; it neither reissues a financial command nor authorizes
execution or settlement. Authenticated production history completeness, financial
guards, effective fencing, cross-writer allocation and activation remain open.
