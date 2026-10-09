# D-build closeout — the checklist for when dispatch ships

*The kickoff checklist's bookend. "Ships" means what the brief's acceptance said
it means — 4A–4D green, the demo folds live on the hub's real books — and this
checklist is the audit of that sentence before anyone repeats it to a stranger.
Same two audiences: **[F]** founder, **[A]** agent. Same authority order: the
adopted spec artifact > `docs/handoff_dispatch_d.md` > habit. The closeout's one
sentence: **the build is done when its claims survive being checked the way the
substrate checks everything — from the log, in the open, misses first.***

---

## 1 — [A] "Shipped," verified against the acceptance (not against enthusiasm)

```
[ ] mix test green (full suite, no exclusions) — and the acceptance lines from
    the kickoff's §7 each map to named tests:
      4A: replay-identical routing · atomic revocation · out-of-envelope never
          acts · parser green against the PUBLISHED fixture set (by hash)
      4B: one unbroken load lifecycle end to end · dwell as a fold · the
          check-call node DELETED (grep for its absence — automation of it would
          be a spec violation, not a feature)
      4C: byte-reproducible invoices · detention lines carrying evidence hashes ·
          every external act paired with its compensator
      4D: the hub's open-book, hours-returned, detention-recovered folds — live,
          recompilable, computed over his FULL stream
[ ] DISPATCH.md exists, normative, spec-shaped, acceptance mapped to tests
[ ] Log.verify_chains :ok · checkpoint emitted and published off-machine
```

## 2 — [A] The spec's account, settled

```
[ ] every divergence flagged during the build (spec vs. brief vs. as-built)
    reconciled in the phase plans — each either conformed or recorded as a
    deviation with its reason; ZERO silent ones (diff the flags against the
    plans' completion notes)
[ ] block-tier nodes: still blocks, every one — or reclassified with evidence
    and a governance signature on the log; list which, if any
[ ] parses are proposals: confirm no code path treats a parse as authoritative
    without operator review (the v0 invariant most tempting to erode last week
    of a build)
[ ] the fixture set earned its keep: fixtures that found parser bugs noted in
    DISPATCH.md — the anonymization pipeline's value, recorded as fact for the
    next section's honesty
```

## 3 — [F] Counsel Tier 2, checked against what go-live actually does

```
[ ] what cleared: dunning wording (2.1) ____ · detention posture (2.2) ____ ·
    transmission authorization (2.3) ____
[ ] whatever is UNCLEARED stays structurally manual: rendered artifacts a human
    reviews and sends, nothing transmitting in the co-op's name — verify the
    software still refuses, don't remember that it does
[ ] where 2.3 cleared: the hub's transmission authorization SIGNED before the
    first automated send; where not, no automated send exists to authorize
```

## 4 — [F] The hub's reckoning (the first real member's misses-first letter, in person)

```
[ ] his envelope: SIGNED on the log (H5 — his signature, his ceiling), and the
    routing history shows zero acts outside it
[ ] his numbers, from his full stream, no cherry-picking (13 P2 — the founder
    cannot curate their own pitch): hours returned ____ · detention recovered
    ____ · escalations raised ____ and how each resolved
[ ] misses first, said to his face before any wave letter quotes his numbers:
    the parses that needed his correction, the invoice that rendered wrong, the
    week the import lagged — his list to add to, our list to own
[ ] his consent to be THE demo: what the invitation wave will show of his
    operation, agreed item by item — his books made the proof; his yes makes it
    usable (bilateral records stay bilateral without it)
```

## 5 — [F] The rails that were waiting, now fed

```
[ ] cockpit live on real exhaust: escalations flowing to the R-queue, ε
    denominators real, guard counters (override/escalation per process) visible —
    mix cockpit.queue shows the real queue, not test residue
[ ] honorarium state re-checked: if counsel cleared payouts during the build,
    the accrued interviewees hear it now (the closeout promise from the field
    phase, kept the day it becomes true)
[ ] the weekly cadence resumes under its next name: build reporting ends, demo
    /operations cadence begins — say where, so the paper trail's quiet spot is
    named (the field closeout's rule, applied to this phase's ending)
```

## 6 — [F] The handoff forward (this checklist's job ends here)

```
[ ] founding_invitation_letter.md: its gate — "after the demo runs" — is now
    TRUE; the letter goes out per its own preconditions and channel rules
[ ] charter_session_agenda.md queued for the cohort the letter assembles
[ ] the next brief (enforcement workflows / consumer surfaces / the stake view —
    whatever governance picks) reads from the substrate and the as-built
    DISPATCH.md; this build's plans close with a final commit noting acceptance
    met, same convention as phases 1A–5B
```

---

*Provenance: acceptance lines and their tests → D-brief §2 [4A]–[4D], the
kickoff's §7 · spec > brief > habit; divergences flagged never silent → D-brief
§0, the repo's standing convention · check-call deleted not automated → the spec's
node deletion; blocks fail closed → 10 §0 · parses-as-proposals · safeguards
before autonomy → 10 §3 · counsel Tier 2 plugs → counsel_briefing.md 2.1–2.3;
uncleared stays structurally manual → the memo's defaults-closed spine · H5
envelope, his signature his ceiling → 10 §2, D-brief invariant 1 · full-stream
folds, no cherry-picking → 13 P2; demo-consent bilateral → 07 §5, the hub's
sovereignty over his own books · cockpit ε/guards → COCKPIT.md, 5A/5B ·
honorarium clearance → honorarium_rail.md, field closeout §3 · wave gated on the
demo running → founding letter's own precondition, 13 §6 · paper-trail quiet
spots named → field_closeout_checklist.md §5, the bookend discipline.*
