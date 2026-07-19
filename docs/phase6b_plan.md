# Phase 6B — Member data export (portable own-data bundle)

> **Status: PLANNED**. Closes the oldest stated-but-unbuilt substrate item:
> SUBSTRATE.md §7 answers "what is exported to a member when they leave" with
> "1A-minimal `export_stream/1` … the full export *workflow* remains 1D" — and
> 1D (chapter scoping, checkpoints, keys) never built it. Not blocked by
> `gate(D)`; no crypto involved (08 §6 escalation stays untriggered).

## Grounding

- `docs/handoff.md` §4a: "What is exported to a member when they leave?
  (their own data, portable)" — a constitutional anti-capture rule.
- `docs/corpus/08_PLATFORM.md` §1: "signed per-owner log export is the
  external-evidence and compliance path."
- `SUBSTRATE.md` §7 (the stated 1B shape: the member's `members/`,
  `memberships/`, `patronage/`, `redemptions/` streams plus the chapter's
  `accrual_rules` stream), §14 (balance reproduced from a verified export),
  §17 (Log named for export on the portable surface).
- Existing code: `Log.export_stream/1` + `Log.verify_export/1` (1A),
  `Log.read_all/1`, `TypeRegistry.spec/1` stream keying, and the
  capital test that already reproduces a balance from a verified export.

## Acceptance [6B]

1. **One call, whole bundle.** A single function produces a member's
   departure bundle for a chapter: every member-keyed stream (`keys`,
   `members`, and the per-entity `memberships`, `patronage`, `redemptions`,
   `throughput`, `floor` streams) plus the chapter rule streams needed to
   reproduce derived state (`accrual_rules`, `throughput_rules`,
   `floor_rules`). Stream membership is decided by the type registry's
   stream keying — never by string-parsing stream ids.
2. **Offline verifiability.** The bundle verifies with no store access:
   per-stream strict decode, signatures, and chain checks via the existing
   `verify_export/1` discipline.
3. **Reproducibility.** A fold over the verified bundle reproduces the
   member's live capital balance (the §14 discipline, now over the bundle).
4. **No surveillance.** The bundle never contains another member's streams;
   the export surface is classified in the no-surveillance enumeration
   (bundle: `own_data`; offline verification, pure over caller input:
   `system`).

## Build steps

1. Add this plan and commit it before implementation.
2. Add `CoopSubstrate.Export` with `member_bundle/2` and `verify/1`,
   reusing `Log.export_stream/1` / `Log.verify_export/1`. No new event
   types; no Log internals touched.
3. Tests: bundle contents + offline verify + balance reproduction; an
   adversarial absence test (member B's streams never appear in member A's
   bundle); classification entries in the no-surveillance surface.
4. Update SUBSTRATE.md §7's export answer to point at the built workflow.
5. Run the focused tests and full suite. Commit only if green.

## Explicitly deferred

- Bilateral obligation-rail export (`obligations/*` are dual-signed pair
  streams; whether a departing member's export includes them is a
  counterparty-policy question, not a mechanism gap).
- The `charter` stream (constants are chapter commons, readable anyway;
  include when a derived value needs one).
- Delivery venue, bundle encryption, and requesting-member authn (the
  1D-shaped middleware noted in §8 query-authn).
- As-of pinning of the bundle (today's export is as-of head; pin when a
  dispute workflow needs it).
- Federation-scoped streams (§8 open question).
