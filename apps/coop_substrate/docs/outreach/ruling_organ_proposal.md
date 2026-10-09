# Proposal: the ruling organ — for when the first contested program wakes

*A decision paper for the session that item 3 of the session template forces: the first
program containing a contested instrument cannot wake until an organ exists to rule on
it (corpus 09 §1: contested ⇒ N, unrepresentable in live use, until a `RulingIssued`
event exists). This paper proposes; the room disposes, decision by decision. The
standing comfort applies with full force here: **if the room decides nothing, every
contested instrument simply stays at N** — the co-op runs, the programs sleep, and
nothing breaks. There is no deadline pressure except the program's own.*

**What this organ is — and is not.** It rules on **instruments and practices** —
whether a financial structure or operating practice is permitted, conditioned, or
forbidden under the constitution's Article III (09 §1). It is NOT a court for member
disputes (those are standing review and governance, 04 §2), not a management veto, and
not a fatwa mill — the corpus is explicit that its own findings register is structural
compliance work, not fatāwā (09 §4), which is precisely why real questions need a real
organ. Its rulings become validation predicates: what it forbids becomes
*unrepresentable*, what it conditions becomes gate checks.

**What's already waiting for it** (the findings register, 09 §2): the fixed-price
buy-down variant (F4, gated N) · paid-collection receivables variants (F3, gated N) ·
the residual conventional fronting shell (F2, ruling pending) · the annual
bounded-necessity reviews (frontier-model use, 08 §7). The first waking program will
add its own.

---

## D1 — The organ's form *(the corpus offers three; it also recommends)*

| option | strength | honest weakness |
|---|---|---|
| **external qualified board** | independence; credibility beyond the membership | distance from operational reality; cost; scheduling |
| **qualified member committee** | native context; cheap; fast | qualification depth; independence optics on hard calls |
| **per-chapter organs + federation appeal** | locality sovereignty | moot today (one chapter); divergence machinery before there's divergence |

**Proposed: the corpus's own default (09 §1) — a federation-level board with chapter
application**: external qualified scholars as the core, with member liaisons for
operational context (present, non-voting on the ruling itself). Rationale in the
corpus's words: adjudication authority should be *a single choke-point with provenance,
like every other authority in the system*. Hybrid composition buys independence AND
context without pretending either alone suffices.

## D2 — Appointment and qualification

**Proposed:** governance appoints by the normal signed process, against **named,
recorded criteria** rather than credentials this paper would be wrong to invent —
the room adopts criteria (recognized qualification in Islamic commercial jurisprudence;
no financial interest in outcomes; willingness to work with the written-predicate
format) and the appointment event cites how each appointee meets them. Removal:
same process, signed, reasoned. **The community networks the founding cohort came
from are the honest first place to seek names** (13 §1's insight applies to scholars
as it did to carriers: recruit where the trust already lives).

## D3 — Cadence and quorum *(09 §5.2)*

**Proposed:** no standing calendar — the organ convenes **per referral** (a contested
instrument arriving is the trigger, same fold-triggered logic as everything else),
plus one annual sitting for the standing reviews (09 §3: bounded-necessity items,
frontier-model usage). Quorum: majority of appointed members; rulings issue with the
votes recorded. Divergent-school positions **recorded in the ruling itself** — the
corpus requires that members see where reasonable scholars differ (09 §1).

## D4 — Scope and divergence *(09 §5.3)*

**Proposed:** federation rulings bind uniformly — because one chapter exists and
divergence machinery before divergence is overbuild. **Revisit clause built in:** at
the second chapter's chartering, this question reopens automatically (recorded as a
review_date on the adopting event); the corpus deliberately left school-plurality
across localities open, and this proposal preserves that openness rather than
foreclosing it (purpose-preserving, 00 Art. I.1).

## D5 — Compensation *(the rent-resolution rule, applied again)*

**Proposed:** declared per-sitting honorarium or retainer, governance-signed —
**never contingent on the ruling's direction, never a share of anything the ruling
enables**. The organ that rules on whether structures disguise yield must itself be
structurally incapable of one.

## D6 — Mechanics *(the part the software already knows how to do)*

- `RulingIssued{instrument | practice, verdict ∈ permitted | conditioned(preds) |
  forbidden, basis, provenance, scope, review_date?}` and `RulingSuperseded` — the
  09 §1 interface, already specified; the events land on the governance stream.
- **A `ruling` role key** enters the declarable set (a one-line charter-cited code
  change, the session-two pattern): rulings are H6 — signed by the organ's own keys,
  multi-holder per quorum, declared through the existing registry.
- **Conditions compile to predicates**: a conditioned ruling becomes gate checks in a
  follow-up code change that cites the ruling event — and on any mismatch between code
  and ruling, **the ruling event wins and the mismatch is a defect** (the charter-wins
  discipline, extended to its third authority).
- Review dates are honored the same way everything else is: a fold surfaces
  rulings past review; the annual sitting works that list.

---

## Defaults if undecided (each decision separately)

D1–D2 undecided → no organ; contested stays N; the waking program sleeps ·
D3 undecided → per-referral only, no annual sitting (the bounded-necessity reviews then
lapse their permissions on schedule — 09 §3's teeth, worth knowing) · D4 undecided →
uniform by fact (one chapter) · D5 undecided → no compensation, which is its own
independence problem — decide this one · D6 is machinery and follows automatically
from D1–D2.

*Provenance: interface + options + the recommended default → 09 §1 · findings waiting →
09 §2 (F2/F3/F4), 08 §7 · not-fatāwā caveat → 09 §4 · cadence/annual review → 09 §3,
§5.2 · divergence left open → 09 §5.3, 00 Art. I.1 · compensation never contingent →
00 Art. IV.4 applied · ruling-role mechanics → SUBSTRATE §15.2 (declarable roles),
session-two code-alignment pattern · contested ⇒ N as the safe default → 09 §1, the
whole system's posture.*
