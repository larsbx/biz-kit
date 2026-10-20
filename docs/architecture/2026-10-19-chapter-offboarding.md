# Offboarding from a chapter

Date: 2026-10-19. Status: **implemented**. Follows
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
- A wrong number of signatures is refused (`signature_count`), and the batch
  stays held.
- `hold/5` and `submit/3` are now the one-command case of the same code.

**Order.** The project offboardings come first, then the key revocations.
The signer's own key comes last, so an administrator offboarding
themselves signs every command with a key that is still declared.

`Offboarding.prepare_chapter/3` builds the batch. `offboard_chapter/3`
first cancels the person's pending enrolment requests anywhere in the
chapter (`Enrolments.cancel/2` now also takes `{chapter}`), then submits
the batch.

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
  - pending requests anywhere in the chapter are dropped;
  - a batch is only for its principal, needs one signature per command, and
    is used once.
- **`SpruceGoose.Web.OffboardingTest`:**
  - the lookup lists the person's key;
  - another chapter's key is refused;
  - a batch other than the one expected is not signed;
  - the batch ends both projects and the key;
  - a second attempt finds nothing to offboard.
- **`FeedTest`, `OffboardingTest`:** a revoked reader's stream ends with
  `revoked`.
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
