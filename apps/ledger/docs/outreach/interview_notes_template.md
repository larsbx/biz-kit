# Interview notes — capture-day template

*Companion to runbook Phase 3. Copy this file per interview into a **private notes
directory outside the repo** — raw notes carry names and lanes, and nothing here goes
on the log or into git; only the typed findings below get entered, same day, via
`mix harness.findings`. Discipline (corpus 11 §1.2): typed findings, not prose; ONE fact
per finding; **quote them** — your paraphrase is where contamination sneaks in.*

---

## Header

```
interview_id:      I-____          interviewee_ref:  IV-____
date / mode:       ____ / call | chat | form         section: D
instrument:        v____ (mix harness.instrument fetch <v> — have it open)
consent granted:   [ ] synthesis   [ ] anonymized_fixtures   [ ] prospect_record
recording:         [ ] yes  [ ] no        seed handed over:  [ ] yes
persona:           [ ] carrier_owner   [ ] dispatcher   [ ] driver
```

## The kind cheat-sheet (tape this up)

| kind | it is... | sounds like |
|---|---|---|
| `process_step` | a thing that happens, in order | "tender hits my email, I check the rate, then I call the driver" |
| `duration` | a time span they state | "invoice pays in 38 days"; "I get 15 minutes to answer or it's gone" |
| `pain` | what costs or hurts | "I eat detention because documenting it takes longer than it pays" |
| `workaround` | their hack around the pain | "anything on I-94 above my floor, I just say yes without reading" |
| `document` | a paper/file that moves | "the rate con comes as a PDF, the BOL comes back photographed" |
| `rent` | a middleman's cut they name | "the broker keeps points I never see" |
| `exception` | a war story — what went wrong | "driver no-showed, load got re-brokered at a loss" ← adversarial gold |
| `tool` | what actually runs the show | "dispatch is a whiteboard and my wife's spreadsheet" |
| `term_of_art` | their word for a thing | what THEY call a tender, a drop, a good broker |

**The load-bearing question (co-3):** *what would you let software accept on your
behalf, and where exactly does trust stop?* — capture the answer verbatim, boundaries
and all. It becomes an envelope default. If you get nothing else, get this.

## Live notes (scratch — per instrument question)

```
co-1 / di-1 / dr-1 (channels / ritual / good dispatch):

co-2 (last accepted tender, step by step):

co-3 (THE trust boundary — verbatim):

co-4 / di-2 (assignment / declines & speed):

co-5 / dr-3 (paperwork & where it sticks):

co-6 / di-3 (exceptions — get the whole story):

di-4 / dr-2 (tools / waiting):

unprompted (things they said that no question asked):
```

## Findings ledger (this becomes findings.json — same day)

| finding_id | kind | body (VERBATIM — their words) | q-ref |
|---|---|---|---|
| F-I-____-1 | | | |
| F-I-____-2 | | | |
| F-I-____-3 | | | |
| *(keep going — a good hour yields 10–20)* | | | |

## Documents collected (each via `mix harness.document`, consent already covers it)

| doc_kind | what it is | collected? |
|---|---|---|
| rate_confirmation / bol / invoice / lease / recording | | [ ] |

## Cross-interview signals (fill after — not during)

- **Agrees with** (corroboration candidates): claim ___ ↔ findings F-___ , F-___
  → `mix harness.corroborate` once k distinct people attest
- **Contradicts** (conflict candidates): ___ ↔ ___ → `mix harness.conflict` — never
  pick a winner in your notes
- **Denylist harvest**: every name, company, lane, MC/DOT you wrote above goes into
  `denylist.txt` NOW, while you remember — fixtures publication depends on it
- **Funnel / hub signal** (corpus 13 §1 — private judgment, not a finding): authority
  age, community pull, yard owned?, would others follow them? → if strong and consent
  includes prospect_record: `mix harness.prospect`

## Same-day close-out checklist

```
[ ] mix harness.interview --id I-__ --interviewee IV-__ --mode __
[ ] findings.json written from the ledger → mix harness.findings findings.json
[ ] documents → mix harness.document ...        [ ] denylist.txt updated
[ ] corroborate/conflict where ripe             [ ] prospect if consented + warranted
[ ] mix harness.status   ← watch the legs move; that's the hour becoming evidence
[ ] honorarium accrued if that was the deal:  mix harness.honorarium ...
[ ] these raw notes filed in the private dir — NOT committed, NOT on the log
```

---

*Why verbatim, one more time: the synthesis fold cannot un-average what you averaged in
your notebook. Conflicts between carriers are model content (11 P4) — your job on
capture day is fidelity, not agreement. And if they say something that kills the idea,
that's a finding too; write it down exactly.*
