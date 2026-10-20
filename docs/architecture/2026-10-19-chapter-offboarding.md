# Offboarding from a chapter

Date: 2026-10-19; admission coordination revised 2026-10-20.
Status: **implemented**. Follows
[offboarding](2026-10-19-offboarding.md) and
[administration](2026-10-19-administration.md). Those left one gap:
offboarding ended a person's grants project by project, but not their
administrator keys. A departed administrator's browser kept governing the
chapter until someone revoked its key separately.

## Decision

An administrator offboards a person from a **whole chapter** in one act.
That act is a batch of existing commands, signed together and appended
together:

1. a `TaskPrincipalOffboardedV1` for each project in which the person holds
   something, ending everything they hold there, as before;
2. a `RoleKeyRevoked` for each governance key of the chapter declared for
   them.

**Why existing commands.** No new event type was needed:
- each command already has its rules (`held_by/3` at admission;
  `cannot_orphan_governance`);
- the key revocations are governance-signed and in the governance history,
  so an export derives the same keys as the live ledger
  (`Export.derive_role_keys/2`, as [own devices](2026-10-19-own-devices.md)
  requires).

**Why one batch.** `Log.append/1` admits a batch whole or not at all. The
person never ends up half offboarded:
- a bad signature on any command refuses all of them;
- if their keys are the chapter's last governance keys, nothing changes,
  because a chapter can never orphan its governance.

## Holding a batch

`Commands.hold_batch/4` holds several commands from one signer as one
unit, and `submit_batch/3` takes one signature per command:

- At preparation, each command is checked against the ledger as the ones
  before it in the batch leave it, as `Log.append/1` checks a batch. So a
  batch that would be refused is refused before anyone signs.
- A batch is single-use, bound to its owner (`{:chapter_offboarding,
  principal}`), and held for five minutes, as a single command is.
- Chapter offboarding checks the signature count and every signature before
  spending the batch. Either refusal (`signature_count`, `invalid_signature`)
  leaves it held. Once submission takes the batch, it is spent even if the
  final ledger guard or governance validity check refuses admission; retry
  with a newly prepared batch. The pending enrolment requests stay intact.
- `hold/5` and `submit/3` are now the one-command case of the same code.

**Order.** The project offboardings come first, then the key revocations.
The signer's own key comes last, so an administrator offboarding
themselves signs every command with a key that is still declared.

`Offboarding.prepare_chapter/3` builds the batch.

**Still complete at admission.** A batch names the projects and keys the
person held when it was prepared. Another administrator may grant them a
project, or declare a key for them, while it waits. So
`offboard_chapter/3` submits it with a guard (`Log.append_if/3`, an
`{m, f, args}` evaluated by the appender itself, against its gate, in the
same call that admits the batch). The guard, `Offboarding.unchanged/5`,
rebuilds the batch from that gate and requires it to be the same.
Otherwise the batch is refused whole (`holdings_changed`, 409) and the
administrator offboards again.

**Requests last, inside the approval coordinator.** After the preliminary
checks, `Offboarding.offboard_chapter/3` calls
`Enrolments.offboard_chapter/4`. The cluster-wide enrolment process submits
the held batch under the unchanged atomic ledger guard, waits for admission,
and deletes this principal's pending requests in this chapter **only on
success**, before handling another message. An error returned by submission
leaves the requests, their codes, expiry times and prepared approvals intact.
Other principals and other chapters are untouched.

Approval already runs in this same process, including both its pending-code
lookup and its call to `Commands.submit/3`. There are two orders:

- **Approval first:** its grant is admitted before offboarding. The final
  offboarding guard either covers it (an already named project), or rejects
  the stale batch (a new project or governance key). Nothing is cancelled on
  that rejection.
- **Offboarding first:** approvals wait through admission and cancellation.
  On success their pending-code lookup fails with `unknown_code`, even if
  the approval was prepared and signed before offboarding. On rejection
  their requests are still available.

This fixes the previously documented check/cancel/append window. A preliminary
holdings check is an early error only; it never authorizes request deletion.

### Transaction and state-machine boundaries

The canonical transaction is `Log`'s signed event-store append. Enrolment
requests and held commands are separate, ephemeral ETS tables owned by their
respective cluster singletons. A SQL transaction cannot enlist these tables.
Deleting first and restoring on error would need to reconcile concurrent
approvals, cancellations and expiry; simply deleting after append in the
HTTP caller would allow an already prepared approval between those calls.
Instead, the existing enrolment state machine serializes admission and
conditional deletion with approvals. No rollback or reservation state is
needed.

The call direction is Enrolments → Commands → Log. Log never calls back into
Enrolments: its guard remains a pure check of its own gate. Every signature,
governance validity rule, orphan check and expected-version store fence still
runs in the existing path. No unsigned ledger event or server signature is
introduced, and neither command ownership nor single-use semantics changes.

This is coordination for the existing live singleton, **not** a durable
transaction across ETS and the event store. A process/node failure still
loses ephemeral requests as documented for enrolment. A timeout or lost
reply is an indeterminate outcome, not a reported admission refusal; inspect
the signed ledger before preparing a retry. If the coordinator dies after
append, its old pending codes die with it. This change adds no stronger
partition/failover guarantee than the existing singleton architecture.

## Over HTTP

```
GET  /api/v1/principals/:id                              → … keys: [{chapter_id, key_id}]
POST /api/v1/principals/:id/chapter_offboarding          {"governance_key_id", "chapter_id"}
     → 201 {id, expires_at, commands: [{type, payload, signing_bytes}]}
POST /api/v1/principals/:id/chapter_offboarding/:held_id {"signatures": [...]}
     → 201 {events: [{event_id, global_seq}]}
```

The person lookup and the preparation are signed reads by a governance key
of the chapter (`Governance.Read`). `Governance.Client.sign_batch/4` decodes
every command and lets the caller judge all of them before signing any.

## The view

**A person in this chapter** gains a section for the chapter. It names the
person's administrator keys, if any, and offers **Offboard from this
chapter**:

- The page builds the commands it expects from what it shows
  (`chapterOffboarding`).
- It signs only if the batch is exactly those commands
  (`device.isExpectedBatch`): each payload exact, each command once,
  nothing missing or extra, in any order.
- All the commands are shown in one confirmation and signed together.

Per-project **Offboard from …** stays for ending one project only.

## A feed says when access ends

Offboarding from a chapter ends the person's feeds. Until now a stream
simply closed, and a page learned of it only through a refused reconnect,
after the browser's reconnect delay.

Now the endpoint sends one last `revoked` event (`SSE.revoked/0`) before it
closes the stream. The page then empties its view, asks where its device
stands, and stops at once. Its own key leaving the chapter's feed works the
same way ([live view](2026-10-19-live-view.md)).

## Verification

- **`OffboardingTest`** (*from the whole chapter*):
  - every project and the person's administrator key are ended in one
    append, at consecutive positions;
  - one bad signature, or a batch that would orphan the chapter, ends
    nothing;
  - an administrator offboarding themselves signs with their own key last;
  - a project granted or a key declared while the batch waited refuses it
    whole (`holdings_changed`);
  - a bad submission keeps the batch and the person's pending requests;
  - a deterministic process barrier grants a new project after preliminary
    validation but before admission: `holdings_changed`, no offboarding
    append, and the exact pending request and its signed approval survive;
  - removing the other governance key at that barrier triggers
    `cannot_orphan_governance` after the guard passes and keeps the request;
  - operator, reviewer and governance approvals queued while offboarding
    waits for the ledger cannot restore access after success;
  - an approval already in admission for a named project is committed first,
    then its new grant is ended by the following offboarding;
  - another principal's requests and this principal's other-chapter requests
    survive successful offboarding;
  - pending requests anywhere in the chapter are dropped;
  - a batch is only for its principal, needs one signature per command, and
    is used once.
- **`SpruceGoose.Web.OffboardingTest`:**
  - the lookup lists the person's key;
  - another chapter's key is refused;
  - a batch other than the one expected is not signed;
  - the batch ends both projects and the key;
  - a second attempt finds nothing to offboard.
  - the same admission race returns 409 without losing the request; a fresh
    successful batch then makes the previously signed approval return 404.
- **`FeedTest`, `OffboardingTest`:** a revoked reader's stream ends with
  `revoked`.
- **`LogTest`:** `append_if/3` admits a batch only when its guard holds;
  the guard is given the appender's gate, and a refusal appends nothing.
- **Node:**
  - `chapterOffboarding` builds the expected commands from a lookup;
  - `isExpectedBatch` accepts the batch in any order, and refuses one
    missing, one extra, one repeated, an altered payload, an extra field,
    another signer or another chapter.
- **Browser (Chromium):** the reviewer also administers the chapter from
  another browser. The administrator:
  1. offboards them from project-2 alone;
  2. then offboards them from the whole chapter: one confirmation listing
     project-1 and the key, never project-2 again.

  The reviewer's key leaves the administrators list. Within 5 s, the
  reviewer's own page drops its devices. The ledger holds the project-1
  offboarding and the key revocation next to each other, both signed by the
  administrator's browser.
- **Mutation:** if the server adds a field the page did not show to the key
  revocation, the page refuses to sign and the browser test fails.

## Limits

- A person's identity bindings and sessions are untouched, as with project
  offboarding.
- The batch covers one chapter. A person in several chapters is offboarded
  from each by an administrator of that chapter.
- `mix coop.offboard` still ends projects only. Administrators do this in
  the view.
- This correction coordinates chapter offboarding. The separate project
  offboarding path retains its existing cancellation behavior.
- Requests and challenges are not a permanent ban. New requests and fresh
  governance-signed grants remain possible; direct governance ledger writes
  are not enrolment approvals and retain their existing authority.
