# Go-live day checklist — the first load, all vantage points at once

*The orchestration sheet for the evening the first load actually runs, when
three (sometimes four) checklists fire on the same freight:
`docs/face_golive_checklist.md` (the network's gates),
`shipper_golive_checklist.md` (her dock), `carrier_golive_checklist.md` (his
operation), and — if his driver is a member on a first solo —
`driver_golive_checklist.md` (the person). This sheet adds no items to any of
them; it sequences them, names the synchronization points, and scripts the
failure branches. **Where it and any checklist disagree, the checklist wins.**
The evening's one rule: every precondition of every applicable checklist is
green BEFORE the tender — a gate failure discovered mid-load is the one script
nobody has.*

---

## 0 — The week before

- [ ] Decide which checklists apply and assign each a runner — one person can
      hold several, but each checklist gets a named owner whose job tonight is
      ONLY its boxes
- [ ] Run every §0 (preconditions) of every applicable checklist NOW, not on
      the day — anything red has a week to fix; anything still red on the day
      postpones the night (see failure branch A)
- [ ] The rehearsals each checklist requires (test-log rails, margin view,
      signature walkthroughs) done and checked off in their own documents
- [ ] Agree the evening's communication plan: who confirms what to whom at
      each sync point below — and the standing silences rehearsed (nothing to
      a rolling driver, nothing into the carrier's roster, nothing about the
      shipper's other freight)

## 1 — Sync point one: all preconditions green → the tender

- [ ] Every applicable checklist's §0 re-verified ON THE DAY (freshness
      matters: `tenderable(c)`, `operable(yard)` where staging is involved,
      the constants read back)
- [ ] The Face checklist's charter and legal gates confirmed one final time —
      they gate everyone's evening
- [ ] Only then: the tender flows (shipper §1, carrier §1, Face §3 — each
      audited on its own sheet)

## 2 — Sync point two: acceptance → carriage

- [ ] The carrier's signed acceptance lands in-envelope (his sheet shows the
      fit; the Face sheet logs the act)
- [ ] The shipper's acknowledgment sent — honest about capacity, per her
      sheet
- [ ] From wheels-rolling to wheels-stopped, the orchestration goes quiet:
      the checklists' silence rules ARE the coordination — no runner "checks
      in" with any other party's side mid-carriage; exceptions surface as
      logged events and wait for parked/delivered handling

## 3 — Sync point three: delivery → the same-day cluster

These four happen the same day, in this order, each on its own sheet:

- [ ] Custody chain complete and verified (everyone's sheets reference the
      same events)
- [ ] The invoice cluster: byte-reproducible, evidence-bound both directions
      (shipper §3, carrier §3)
- [ ] The money cluster: margin disclosed to the carrier-owner, split applied
      per the declared ratio, patronage credited with rule ids (Face §3,
      carrier §3)
- [ ] Settlement state confirmed external and attested

## 4 — Sync point four: the debriefs (separate, bilateral, same day where possible)

- [ ] Shipper debrief, carrier debrief, (driver debrief, parked) — each per
      its own sheet, each bilateral: no party's answers are relayed to
      another party, and no combined "retro" puts counterparties in one room
- [ ] ONE misses list per checklist, written in its own document's terms —
      then ONE governance aggregate across the evening: counts and event
      references, no adjectives, individual debrief content stays bilateral
- [ ] Every follow-up clock started: shipper trial, carrier Face, (driver
      trial) letters — their own schedules from here

## 5 — Failure branches (scripted now, because mid-evening is too late)

- **A. A precondition fails on the day (before tender):** the night
  postpones, plainly, to everyone who was expecting it — "a gate held" is
  the honest sentence, and it's a better founding story than a night that
  limped. No partial go-live, no "we'll paper it tomorrow."
- **B. Something fails mid-load (after acceptance):** the load COMPLETES
  under the terms it started with — in-flight completion is the standing
  rule at every scale — while the failure is logged, escalated to the
  R-queue, and leads tonight's misses. No mid-load renegotiation, no
  mid-load rescue theater.
- **C. The failure is a checklist box that was checked and shouldn't have
  been:** that's the worst one, and it's a process defect before it's an
  operational one — the box, the checker, and the gap go in the governance
  aggregate by name of the GAP (not the person), and the checklist itself
  gets the fix before load two.
- **D. Any failure branch fires:** no load two until the misses list and the
  fix exist — the family's no-velocity rule, now with teeth across all
  sheets at once.

## 6 — The evening's refusals (the union, verified once)

- [ ] Each checklist's own refusal section verified by its runner — this
      sheet adds none and waives none
- [ ] The one orchestration-level refusal: **no cross-party leakage** — the
      evening produces three bilateral stories and one aggregate, never a
      combined narrative that tells any party about another's terms, debrief,
      or numbers

---

*Provenance: an orchestration of checklists that own their own rules —
checklist-wins, same as every index. Sequencing (preconditions before tender,
in-flight completes, no velocity before the reckoning) → the first-night
family's shared rules, applied jointly. Bilateral debriefs, no cross-party
leakage → 07 §5, the no-surveillance posture at orchestration scale.
Failure-branch honesty ("a gate held") → the gates' whole purpose; postponement
as success → 09 §1's not-yet, operationally.*
