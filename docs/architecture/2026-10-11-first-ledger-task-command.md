# First task command on the common ledger

Date: 2026-10-11. Scope: the first implementation stage of the
[single-source target](2026-10-11-single-source-of-truth.md).

The notes/AshEvents spike is retired. A bounded task command now uses the
existing `CoopSubstrate.Log` appender and PostgreSQL EventStore. Its task and
grant state rebuilds from accepted events alone. The current SpruceGoose and
Dispatch production writers are still in place; this is an isolated rehearsal
path, not a completed production cutover or a second audit bridge.

## Removed machinery and retained history

Removed `SpruceGoose.Notes`, `Notes.Note`, `Events.Event`,
`Events.ClearAllRecords`, the Notes domain registration, and the `ash_events`
dependency/lock entry. Repository-wide source search found no supported caller
of the Notes domain or its replay hook. Other applications do not use
AshEvents. No replacement notes subsystem is introduced.

The original spike migration and resource snapshots remain unchanged. There
is no migration dropping `notes` or the SpruceGoose `events` table, and no
database data has been deleted. Production data counts are unknown: removing
unused code is not evidence that stored notes are empty. Before physical
retirement, inventory these tables, preserve required rows and historical
bytes, and record their digests/custody locations. Do not apply a generated
Ash migration that proposes dropping them as part of this code removal.

## Command and authority contract

| Event | Signer and admission rule | Result |
| --- | --- | --- |
| `TaskOperatorGrantedV1` | Currently declared chapter governance key; explicit tenant/project, principal, operator key ID and public key. | A scoped grant identified by the grant event ID. No cooperative membership or email linkage is implied. |
| `TaskOperatorRevokedV1` | Currently declared governance key; exact original chapter/tenant/project scope and active grant reference. | Revocation is folded before later commands, including within an atomic batch. |
| `TaskBaselineRecordedV1` | Currently declared governance key; previously absent task key, preserved source digest, legacy row ID, definition digest, title and definition of done. | An inbox task at aggregate version 1. This is a signed baseline attestation, not a new operational task-admission API or proof of historical approvals. |
| `TaskProposedV1` | Operator signature must match the referenced active grant, principal and exact chapter/tenant/project scope; task exists in inbox; expected version matches; lifecycle version is 1. | Inbox becomes proposed, task version increases to 2, and the reply identifies the accepted event hash and global position. |

`chapter_id` remains the ledger namespace. Tenant, project and task IDs are
separate signed payload fields. Task streams are
`<chapter>/tasks/<tenant>/<project>/<task>`; grant streams are
`<chapter>/task_grants/<tenant>/<project>`. New stream segments are bounded to
128 ASCII letters/digits/dot/underscore/hyphen characters, beginning with a
letter or digit; slashes and empty values are rejected before persistence.
Legacy IDs that need a different representation require a reviewed mapping;
this code does not rename imported records.

These governance operations fail closed until a key is explicitly declared.
The existing governance genesis trust-on-first-use rule is retained; rehearse
in a fresh namespace with a reviewed genesis/checkpoint. Existing economic
events keep their original bootstrap and bilateral-signature semantics.

The baseline's source/definition digests refer to preserved evidence artifacts.
The append gate verifies their shape and governance attestation; it does not
fetch artifacts or claim to validate the old database from a digest alone.
Recording a production baseline still requires writer fencing, source export,
artifact custody and parity checks. No baseline importer or production caller
is enabled by this change.

`CoopSubstrate.Tasks.proposal/1` builds the unsigned envelope;
`Envelope.sign/3` supplies the operator signature;
`CoopSubstrate.Tasks.propose/2` submits it to the same `Log.append/2` path used
by other ledger events. Direct `Log.append/2` gets the same admission checks.
The command does not accept an Ash record or a caller's reconstructed view as
authority. The grant proves possession of a governed signing key; OIDC/human
principal linkage remains later work.

Only **inbox -> proposed** is implemented. This is the transition in
`SpruceGoose.Workflows.Lifecycle` version 1 with no readiness, SOP, artifact,
predecessor, TODO-completion or execution requirement. Those existing checks
remain in their current paths. Queuing, readiness, execution, completion,
hierarchy, definitions and grant migration must be covered before switching
the live orchestration writer. Baseline events cannot overwrite existing tasks.

## Ordering, retry and replay

The appender checks the command against its committed task/grant fold and
earlier events in the same batch. Append failure advances neither that state
nor the chain head. Task versions are optimistic aggregate preconditions;
global order is acceptance order, not the author's timestamp.

A single-command retry with the same event ID, signed core and signatures
returns its original acknowledgement without appending again, even after
restart or subsequent grant revocation. It acknowledges an already accepted
fact and grants no new authority. Reusing that ID with different signed content
is refused. Duplicate retry behavior is deliberately limited to this new task
proposal; legacy append behavior and mixed-batch retries are unchanged.

`CoopSubstrate.Projections.Tasks` is the pure fold used both by the append
gate and `Log.replay/2`. The response's `global_seq` is the watermark for a
future persisted read projection. No task Repo, second event store, projector
worker, dual-write hook, outbox or external effect was introduced. Replay has
no execution side effects, and the old canonical encoding remains in use.

## Verification and next boundary

`apps/coop_substrate/test/task_commands_test.exs` exercises the real EventStore:
signed append, independent task-stream export/rebuild, as-of replay, competing
commands, invalid scopes/signers/principals, governance and grant revocation,
atomic batch rejection, restart/idempotency, conflicting IDs, store failure,
and rejection despite a forged/stale local projection.

The Consolidation workflow compiles the umbrella and runs the common-ledger
and SpruceGoose suites against disposable PostgreSQL 16 databases. Local
verification results and the exact CI head are recorded in the implementation
PR. Historical migrations are replayed, including the retained spike tables.

The next implementation boundary is task admission/definitions plus queued
and ready transitions, with ledger-derived artifact/predecessor/SOP facts.
It must replace an entire covered write path and provide a projection
rebuild before enabling that path on live tasks. The old writer then needs an
explicit fence; configuration rollback alone cannot recover new ledger facts.
