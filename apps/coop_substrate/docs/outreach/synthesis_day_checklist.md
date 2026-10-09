# Synthesis day — the checklist for when interviews wrap

*Runbook Phase 5, expanded into a working day. This is the judgment day of the whole
field phase: everything before it was fidelity (capture their words exactly); today is
the one day your opinion is the input — and the machinery is built so your opinion is
visible, signed, and reviewable. Block out the day; don't synthesize between errands.*

---

## 0 — The day before (preconditions; don't start synthesis with a leaky bucket)

```
[ ] every conducted interview is entered (notes close-outs all done)
[ ] every debrief's §4 swept: pending corroborations and conflicts APPENDED —
    the model binds to what's on the log, not what's in your notebook
[ ] instrument change candidates parked or published (a version bump today is fine;
    mid-synthesis is not)
[ ] no consent conversations in the air — if someone is wavering, resolve or wait;
    a mid-synthesis revocation restarts you (see step 5's compare)
[ ] mix harness.status: interviews / corroborated / documents legs all met —
    if a leg is short, today is not synthesis day; the answer is more interviews,
    never more imagination
```

## 1 — Freeze and compile (morning)

```
[ ] no more capture entries from here to adoption — the world holds still
[ ] mix harness.model publish        → write down the model_hash: ____________
[ ] mix harness.model show           → read it END TO END, coffee first
```

## 2 — Reading discipline (what to look for, in order)

```
[ ] core vs observations: how much survived corroboration? A thin core with fat
    observations means k people haven't yet said the same things — more interviews.
[ ] conflicts: if the list is EMPTY, distrust your capture before you trust your
    carriers — working carriers disagree about detention, timing, and brokers;
    zero conflicts usually means the interviewer smoothed (11 P4's whole point)
[ ] exceptions: this list becomes the dispatch tool's adversarial test suite (11 §0).
    Is every war story you remember hearing IN it? A missing horror story is a
    missing finding — go check the notes, append it, restart from step 1
[ ] envelope_default_candidates: do they match the co-3 verbatims you collected?
    (the v0 heuristic is crude — your classifier judgment corrects it, next step)
[ ] durations & documents: sane, roughly complete
```

## 3 — The classifier (the judgment hour; classifier.json, per core claim)

The decision procedure, per claim — write down WHY for each, it's reviewable forever:

```
does executing this act require a human signature by law or charter
  (statutory attestation, governance, unbounded commitment, claims/legal)?
      → {"h": "H1".."H6"}                          (lands R)
is it religiously or legally contested, pending a ruling?
      → "contested"                                (lands N — 09 gated-N)
did carriers DECLARE this inside their own trust boundary (the co-3 verbatims
  are your evidence — quote them in your why-notes)?
      → {"enveloped": true}                        (lands A)
anything else — including "I'm not sure":
      → LEAVE IT OUT of the classifier             (lands block: the safe wrong answer)
```

```
[ ] classifier.json written; every entry has a why-note in your private synthesis memo
[ ] nothing classified "enveloped" without a carrier's verbatim behind it
[ ] count the blocks without shame — block is deferral, not failure; the D build's
    phase plans revisit them against the adopted spec
```

## 4 — Spec compile and read

```
[ ] mix harness.spec publish classifier.json  → record the THREE hashes
[ ] read the spec artifact: every node's tier what you intended? adversarial cases =
    the exceptions list? classifier embedded (your judgment travels with the spec)?
[ ] classifier hygiene errors (unknown claims) mean YOUR file drifted — fix, re-run
```

## 5 — The staleness compare, then THE signature (do not swap this order)

```
[ ] mix harness.model publish — AGAIN. If the printed model_hash ≠ step 1's, the
    world moved under you (late finding, revocation). Not a crisis: restart from
    step 2 with the new model. The hash binding exists to catch exactly this;
    adopting yesterday's evidence is what it makes unrepresentable.
[ ] hashes match → mix harness.adopt --spec __ --defaults __ --model __
    (governance key; read the prompt; typing "confirm" IS the pipeline's one
    human signature — 11 §1.4. Take the ten seconds it deserves.)
```

## 6 — Close the day

```
[ ] mix harness.status — adopted: true; fixtures now the named short leg
    (fixtures are their own session — runbook phase 6; don't anonymize tired)
[ ] mix harness.checkpoint → publish the blob off-machine (the adoption is now
    committed history someone else can verify)
[ ] weekly status gets a milestone line; debrief-of-the-day: one paragraph in the
    private memo on what you classified and why the blocks are blocks
```

---

*Provenance: freeze/compile/read → 2C recompilable-model machinery · zero-conflicts
suspicion → 11 P4 · exceptions-as-suite → 11 §0 · classifier procedure → 10 §0–§2
(H-set; unclassified ⇒ block), 09 §1 (contested ⇒ N) · enveloped-needs-verbatim → co-3,
D-brief invariant 1 · staleness compare → SpecAdopted model_hash gate (2C, tested) ·
the one signature → 11 §1.4 · fixtures-not-tired → 2D anonymization predicate (it fails
closed, but your denylist is judgment).*
