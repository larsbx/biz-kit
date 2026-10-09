# Charter-drafting session two — accrual economics

*Convened per session one's roadmap: **before the first thing bills**. This session's
comfort, said at the top and meant: accrual rules are versioned in the ledger and apply
**forward only** — every credit ever made records the rule that made it, so a weight
this room gets wrong is correctable next month, visibly, without rewriting one cent of
anyone's history. You are not carving stone tonight; you are declaring version one.
Same rules of the room as session one: 1M1V, timeboxes, undecided stays closed.*

**Pre-reads:** the value equation, one page (corpus 02 §1: member value = patronage +
share appreciation + rate uplift + wage) · the placeholder rule as it stands
(`capital-accrual-v1`: credited = amount × weight(kind), in plain words) · "dues are
not patronage," three sentences (04 §4: dues buy access; patronage is value you
CREATED flowing back).

---

## 0 — Recap + the forward-only comfort *(10 min)*

Session one's signings verified from a member's copy (two minutes, live — the habit).
Then the versioning promise above, demonstrated: the test log, a rule change, the old
entries byte-identical. What this room declares tonight is v1, not forever.

## 1 — Patronage, concretely *(20 min)*

What accrues to a capital account and why it's separate from votes (economic
participation scales, governance never — 00 Art. IV.1). Live demo on the test log:
a patronage event lands, a balance query answers, a redemption schedule shape shown.
The machinery is built; tonight fills in its numbers.

## 2 — The kinds: a closed set *(45 min — decide)*

Patronage kinds are a **closed taxonomy** — an unlisted kind is unrepresentable, which
is why the list is a governance act. Tonight's honest scope: declare kinds only for
what will measurably happen soon, reserve names for what's designed but dormant:

| kind (proposed) | wakes when | decide tonight? |
|---|---|---|
| `routed_freight` — margin share on loads members choose to route | the brokerage | reserve the NAME; weight deferred to item 5 |
| `backhaul_participation` | matching goes live | reserve |
| others the room proposes | — | list, reserve or reject |

*(Dues are deliberately absent: dues ⊥ patronage, 04 §4 — collecting them creates no
capital claim, by design, said aloud.)*

## 3 — The weights + who accrues *(45 min — decide)*

- **The rule**: keep `capital-accrual-v1` (weighted-linear) with the weights this room
  sets per declared kind + a default — or commission a v2 shape (a new rule module,
  new id; the registry pattern exists). Simple and revisable beats clever and stuck.
- **Who accrues — the flagged placeholders come home**: does a **probationary** member's
  participation accrue? A member **in cure**? **In hardship**? The software currently
  says yes to all three, *marked as awaiting exactly this room*. Decide each.
  **Honesty note:** these live as flagged code semantics, not constants — the room's
  decision is signed onto the log tonight and the code is aligned in a follow-up
  change that cites tonight's event; if code and charter ever disagree, the charter
  event wins and the mismatch is a defect.

## 4 — Redemption standard terms *(30 min — decide the defaults, keep the deferral)*

Each redemption schedule carries its terms in the event (years, annual cap, FIFO);
tonight sets the **standard** terms stewards open schedules with: years ____ · annual
cap basis ____ · FIFO confirmed · death-to-estate confirmed (the machinery routes it
already). The *enforcement workflow* (caps checked against balances at the gate)
remains flagged-deferred — data model complete, engine later; the room should hear
that plainly.

## 5 — The I1 question, opened and dated — not answered *(20 min)*

When the brokerage wakes, its captured margin splits: **patronage now vs retained for
the co-op's growth**, with a pre-declared decay schedule (corpus 03 §6.3, 04 §5 I1).
Tonight's only decision: **the deadline** — this ratio must be declared before the
Face routes its first load, and whoever's here then decides it. Set the trigger, not
the number.

## 6 — The zakāt fold *(5 min — awareness, no decision)*

Per-member, member-sovereign, computed on request from their own events (05 §7). It
exists; whoever wants theirs asks; nobody else ever sees it.

## 7 — The signing *(20 min)*

`AccrualRuleActivated` with tonight's kinds + weights · `CharterConstantDeclared` for
the accrual-eligibility decisions (item 3), redemption standard terms (item 4), and
the I1 trigger (item 5) · checkpoint emitted and published while the room watches ·
the verification instruction sheet again — same as session one, because the habit is
the institution.

## 8 — Close

Code-alignment follow-ups listed with their charter-event references (item 3's
honesty note). Session three triggers restated: per program, as each wakes —
constants before first evaluation, always.

---

*Provenance: forward-only versioning → 1B §11.4 machinery (as-of byte-stable, tested) ·
value equation → corpus 02 §1 · dues ⊥ patronage → 04 §4 · closed kinds → 05 P1
discipline (closed sets), registry pattern · probationary/cure/hardship placeholders →
1B/1C plans (flagged for exactly this room) · redemption data-now-workflow-later →
1B §11.5, SUBSTRATE §8 · I1 declare-before-first-evaluation → 03 §6.3, 00 Art. IV.2 ·
zakāt → 05 §7 · charter-wins-on-mismatch → 00 Art. I.1 current-state supremacy.*
