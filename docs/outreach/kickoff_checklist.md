# Field-phase kickoff — the checklist that ties the kit together

*Work top to bottom, once, before the first pitch. Each line points at the document that
owns it — this page sequences, it doesn't repeat. When every box is ticked, the next
artifact this project produces is a carrier's handwriting on a slip.*

---

## 1 — The machine (an afternoon)

```
[ ] mix test green (203 tests) · cargo test green — a red suite means stop
[ ] HARNESS_KEYS_DIR set to a dir that gets backed up; artifact dir configured
[ ] mix harness.keys genesis  → genesis_checkpoint.bin PUBLISHED OFF-MACHINE
    (gist / second host / your phone — the trust-on-first-use mitigation, SUBSTRATE §15)
[ ] mix harness.constants --n _ --c _ --d _ --k _
    (conservative; suggested starts in runbook 0.3; revising later is allowed and VISIBLE)
[ ] cockpit/open_cap declared if you'll use the R-queue during field work (optional now)
[ ] mix harness.instrument publish   (after reading seed_d — runbook 0.4; edits = new
    versions, diffable, so your question drift is auditable)
[ ] mix harness.status → gate=false with every leg NAMED. That page of short legs is
    the field phase's to-do list; everything below exists to shrink it.
```

## 2 — Counsel (start now; it runs in parallel)

```
[ ] counsel_briefing.md: fill the header + the state list (item 1.1), attach the listed
    docs, send
[ ] until answers land: recording stays OFF everywhere unconfirmed (notes-only), and
    honoraria stay accrue-only (the machine enforces the second; you enforce the first)
```

## 3 — The paper kit (an evening)

```
[ ] friendly_carrier_onepager.md — fill BOTH founder brackets; the relationship line is
    the actual pitch
[ ] field_faq.md — read until the answers are yours, not the page's; fill the
    "what do YOU get" bracket honestly
[ ] seed_slip.html — print a handful (3/page, cut); carry blank, always
[ ] consent_ceremony_script.md + revocation_ceremony_script.md — read aloud once each;
    the spoken promises must be exact
[ ] interview_scheduling_email.md — brackets ready to fill per person
```

## 4 — The private side (half an hour; this is the sensitive half)

```
[ ] private notes dir created OUTSIDE the repo
[ ] recruitment_tracker_template.md copied there — first 15–20 names entered (it takes
    a long list to land 5–8; recruit toward persona coverage from day one)
[ ] interview_notes_template.md copied there, one per scheduled interview
[ ] backups split TWO ways: keys dir separate from notes/tracker — the two sensitivity
    classes never share a basket
[ ] weekly_status_template.md: pick the weekday; put it in your calendar now
```

## 5 — The dry run (one hour — and it's also the proof)

Rehearse the whole arc on the REAL log, as one fake person, then revoke them: the
exclusion machinery cleans every count — which is simultaneously your rehearsal, your
end-to-end verification, and the demo you promised carriers you could do live.

```
[ ] consent ceremony, out loud, on IV-rehearsal — slip filled by hand, read back
[ ] a 10-minute fake interview → notes template → findings.json → mix harness.findings
[ ] one fake document → mix harness.document
[ ] mix harness.status — watch the legs move
[ ] revocation ceremony, out loud, script and all → mix harness.status — watch them
    move BACK; that reversal is the promise, working
[ ] time yourself: consent under 10 minutes? revocation under 5? if not, run it again
```

## 6 — You are ready when

```
[ ] status shows gate=false with declared constants and named legs (not :constants_undeclared)
[ ] genesis checkpoint exists off-machine; keys and notes back up separately
[ ] counsel memo sent; recording rules known for your first interview's state
[ ] both ceremonies rehearsed aloud; the dry-run revocation flipped the counts back
[ ] one-pager brackets filled; slips printed; tracker has real names with next actions
[ ] you can answer the FAQ's "what's the catch" without looking
```

Then: the first name in the tracker, the one-pager, and the ask. From here the loop is —
**pitch → schedule → ceremony → capture → same-day entry → weekly status** — until
`mix harness.status` says `gate=true`, at which point the runbook's phase 7 and the
D build brief take over.

---

*Everything above is sequencing; authority stays with: docs/runbook_gate_d.md (the
operating manual) · the ceremony scripts (the spoken word) · counsel_briefing.md (the
legal perimeter) · docs/corpus/ (the constitution behind all of it).*
