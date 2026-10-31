# Source-bound EventStore admission increment

Dependency: PR #199, including its proof-only Lean 4.35 repair. This is a
recording adapter and real-store acceptance target. It adds no financial
command, execution permission, settlement authorization or production wiring.
TigerBeetle remains the financial commit authority.

## Boundary

`CoopSubstrate.Log.start_link/1` accepts a trusted host option
`outcome_source_snapshot: %{destination: destination, origins: origins}`.
Requests through `append/2` and `append_if/3` cannot provide that configuration.
Without it both new source outcomes and source checkpoints fail closed.
The existing application supervisor does not populate it.

An origin key is `{home, {:bytes, cluster_128}, {:bytes, generation_64}}`.
Its value contains `keys: %{key_id => ed25519_public_key}` and a fixed list
`groups` of complete original source groups in one-based replay order. A group
contains exactly `home`, `cluster`, `generation`, `ordinal`, `anchor`,
`native_transfer_ids`, `native_evidence` and `outcome`. The anchor is the first
original 128-bit transfer ID, never the ordinal. Native IDs are not ordered or
incremented by this adapter. Evidence and outcome retain complete canonical
bytes; no digest-injectivity premise is used for duplicate/body equality.

The host MUST construct this immutable snapshot from complete authenticated
original native history. This increment validates its shape, contiguous
ordinals, unique anchors, canonical encodings and the signatures of incoming
envelopes against its pinned verifier keys. It does not prove native range
completeness, interpret TigerBeetle financial evidence, construct the trusted
snapshot or support live snapshot succession. Test snapshots are fixtures, not
native-verifier conformance evidence. A production host must not populate this
option from notifications or unverified caller data.

The source protocol requires exactly one pinned verifier per delivery envelope.
Generic envelopes permit several distinct keys with the same required role;
such a fully signed envelope must receive `:unverified_source_outcome` from this
port, rather than terminate the Log appender. The regression first reproduced a
`FunctionClauseError` in the prior source matcher. It now checks both write APIs
for fresh and retried outcomes and checkpoints: the writer stays alive, no
extra event or cursor is committed, and a subsequent single-verifier checkpoint
succeeds. Signature validation and the source-slot/body rules are unchanged.

## Persistence and recovery

`TigerBeetleOutcomeRecordedV1` signs the full group plus the receiving
destination. Its chapter must equal its source home. The accepted envelope
itself is the binding and original receipt for
`(home, destination, cluster, generation, anchor)`.

The Log checks source membership, pinned signer, namespace, slot and exact body
inside the serialized appender before assigning chains or appending. Source
admission requires one event per call; mixed batches cannot smuggle a duplicate
or checkpoint an outcome before a separate durable admission. Both generic
write APIs run these checks, independently of caller guards or external reads.
The accepted receipt is returned on an exact-body retry, including a delivery
with a different envelope ID, pinned signer, signature or timestamp. Changed
body bytes never replace or append another accepted outcome for the slot.

A rebuildable in-memory index is folded exclusively from accepted signed
canonical events. Recovery first audits signatures and both hash chains, then
checks binding/ordinal uniqueness and checkpoint consistency. It retains the
complete original envelopes. There is no post-append uniqueness table. A second
stale appender can pass its local absence test, but cannot pass the canonical
ledger's expected-version check. It stops and must rebuild before retrying.

The first accepted outcome durably pins one destination for the physical Log.
Configuration inconsistent with that accepted destination refuses startup.
An enabled snapshot must also retain every accepted group with its exact bytes
and pinned historical verifier key; changing or forgetting one refuses startup.
Independent destinations use independent EventStore namespaces. A request
cannot alias the same physical Log with another destination to append again.

`TigerBeetleOutcomeCheckpointedV1` signs its scope, next ordinal, original anchor
and the hash of the original accepted receipt. It can advance only one step,
against a binding already present in the committed fold. Gaps, prospective
receipts and cross-scope receipt hashes fail. Exact checkpoint retries recover
the original checkpoint receipt. `Log.outcome_cursor/2` is a read of that fold;
no separate operational cursor can override these signed prefix facts.

## Model correspondence and acceptance

| Formal contract | Concrete check | Real EventStore test |
| --- | --- | --- |
| `VerifiedAt`, `slotAt` | fixed host snapshot, pinned verifier, exact canonical group, distinct ordinal/ID | unknown bytes/key/destination rejected; IDs 901 then 17 |
| `recordOutcome`, `at_most_one_append` | source decision in both Log write paths; ledger expected version | concurrent independent stale appenders; stale external read plus `append_if` |
| `exact_retry_stutters`, `changed_body_cannot_replace` | retained payload equality and original assigned envelope | changed delivery ID/key/time; changed body/evidence/ordinal |
| `lost_reply_retry_stutters`, `crash` | audited ledger replay and derived-link repair | block derived stream row, observe canonical commit, kill appender before reply, recover receipt |
| `admission_does_not_checkpoint` | outcome fold leaves cursors unchanged | append/restart/lost acknowledgment all retain cursor zero |
| `missing_append_cannot_checkpoint`, `checkpoint_preserves` | next ordinal plus already durable exact receipt hash | out-of-order group, missing predecessor, prospective receipt and mixed batch refused |
| `independent_destination`, `independent_cursor` | scoped keys and physically independent destination namespaces | separate durable PostgreSQL schemas; reopen first after second |

The signed replay workflow checks the exact PR source head, compiles with
warnings as errors, checks formatting, and runs these tests plus the existing
Log/signed-replay regressions with two order seeds. Source changes also trigger
the complete Lean/Quint workflow, with fresh kernel replay, unchanged axiom
allowlist, bounded checks, nonvacuity witnesses and mutation controls.

These tests establish inspectable implementation correspondence, not a
mechanically checked SQL/Elixir refinement theorem. Hosted exact-head formal
AND integration acceptance is required before integration. Unrelated queued or
failed repository checks must be reported separately; local success does not
replace the hosted acceptance gate.

## Integration acceptance follow-up (2026-10-31)

Refresh against current main preserves the Dispatch proof module, its axiom
audit, and every existing Quint check alongside outcome admission. AgentCore's
PostgreSQL lane failed before its dispatch assertions because its trusted
`TaskCreatedV1` fixture omitted the required operator authorization fields.
The fixture now names its existing operator grant and lifecycle version;
production admission and delegation checks remain unchanged.

Federation's full-lock and reachable-graph audits independently identified
Bandit 1.14.0 as affected by GHSA-pxjf-g536-7r93. Upgrade only Bandit to 1.14.1,
with the Hex release and archive checksums checked against the published
package. Eatsbot and federation minimum patch constraints now exclude 1.14.0.
The full-lock audit and all adversarial transport requirements remain blocking.
Primary release source:
https://github.com/mtrudel/bandit/blob/1.14.1/CHANGELOG.md

The Location driver trial timed out after 30 seconds in Android's signed offline
queue scenario. Other driver trials and the browser/courier lanes passed in
that run. This establishes an intermittent acceptance failure, not its cause;
the unchanged failed job is retried, with no timeout increase or assertion
removal. New source heads require fresh acceptance rather than inheriting that
retry's result.

The additional real-store signature regression exercises fresh outcomes,
exact-body retries and checkpoints through both Log write APIs. Invalid
signatures must fail before cached receipt recovery, leaving the canonical
ledger and destination cursor unchanged.

Merging this recording adapter does not release production financial writing
or execution. Release still requires independently authenticated native-history
completeness, safe snapshot succession, writer/generation fencing and the
remaining financial release obligations. The supervisor supplies no source
snapshot, so source outcome and checkpoint admission remain disabled by
default. Storage refinement remains an explicit unproved correspondence.
