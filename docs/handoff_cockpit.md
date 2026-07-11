# Hand-off: The Cockpit — R-Queue + Boards (Coding Agent)

**Scope of this hand-off:** the single-operator cockpit of corpus `10_AUTONOMY.md` §5 —
the R-queue as substrate machinery (decision-ready items, deadline-ordered, resolved by
signed acts) and the derived boards (guard board, envelope heat, B_op accounting, fold
health), surfaced through the existing CLI. This is the seam the D build's
`EscalationRaised` lands in (`docs/handoff_dispatch_d.md` §3.3) and the discipline that
keeps one person in control without becoming a bottleneck or a rubber stamp.

It is NOT a UI (a TUI/web cockpit is the first consumer app's brief), not the veto-window
machinery (no veto-eligible acts exist until H1/POA work — the feed ships as a seam), and
not workflow content: *what* escalates is each domain's business; this brief owns the
rail items ride and the views the operator reads.

**Read before coding:** corpus 10 §5 (the load model, decision-ready discipline, the
five cockpit panes, "control ≠ impunity"), §6 P9–P12, the §6 adversarial suite (queue
flooding, deadline forgery); 04 §7 (the Operator as a typed capability set; stateless
role); 08 §5 (guards — v0 is counters, estimators accrete); `SUBSTRATE.md`, `HARNESS.md`.

---

## 0. Non-negotiable invariants

1. **The operator never assembles, only judges and signs** (10 §5). An R item is
   unrepresentable unless **decision-ready**: packet (fold/grade/provenance references),
   recommendation, bounds, compensation path, and deadline — required payload fields plus
   gate checks, so an incomplete item is rejected at append (the substrate-native form of
   10 P10's "returned to the emitting agent as a defect"). The emitting agent fixes the
   packet; the operator never does.
2. **Deadlines derive from log events** (10 §6 adversarial: forgery unrepresentable).
   Every deadline carries a `basis_ref` (the event hash it derives from). **FLAGGED v0
   limit:** the gate checks the basis *exists*; mechanically re-deriving `deadline_ms`
   from basis + a declared per-class constant is the full rule and lands when the first
   real deadline class (claim notice) does.
3. **Everything derived, zero private state** (10 §5, P11): the queue, every board, and
   every count are pure folds; the cockpit view is `as_of:`-reproducible; succession
   remains a key ceremony because no knowledge lives in the person.
4. **Resolutions are on-stream signed acts** (10 P12): `approved | declined |
   returned_defect`, each a gated event; approval never executes the escalated act
   itself — it authorizes, and the acting domain appends its own consequent event
   referencing the resolution (provenance chain terminates in the human at the
   resolution, 08 §1).
5. **B_op breach is a design finding, never staffing** (10 P9): when `Σ cost(open+resolved
   items in period) > B_op`, the fold reports it and a structural-finding event is
   emitted (guard-shaped) — nothing about it suggests hiring; the lever is ε(π) tuning
   (corridors, envelopes, grade floors) or reclassification.
6. **Queue flooding is structurally bounded** (10 §6 adversarial): a per-process cap on
   concurrently open items (declared constant); at the cap, further escalations from
   that process are rejected — time pressure cannot be manufactured by volume.
7. **Fear is not a gate criterion** (10 §0): nothing in this brief adds a review click
   to an A-tier act. The queue holds only what the H-predicate or an envelope boundary
   already routed to R.

## 1. The rail (event sketch — the phase plan finalizes fields)

```
EscalationRaised{item_id, process, act_type, packet_refs, recommendation, bounds,
                 compensation_path, deadline_ms, basis_ref}     — agent/steward-signed
EscalationResolved{item_id, verdict ∈ approved|declined|returned_defect, reason?}
                                                                — operator-signed
StructuralFindingRaised{kind ∈ b_op_breach|epsilon_breach|chronic_override, process,
                 evidence_refs}                                 — emitted by the fold’s
                                                                  guard pass, steward-signed
```

Gate: `item_id` unique; open-cap per process; resolution only for open items; verdict
closed-set. Constants (declared, 04 §9): `B_op`, `ε_max(π)`, `cost(act_type)`
(**FLAGGED PLACEHOLDER**: per-act-type declared minutes — measured costing is future),
`open_cap(π)`, period length.

**Who signs resolutions — decision:** v0 uses the **steward** role key; a dedicated
`operator` role in the declarable set is the honest 04 §7 shape and is **flagged** as a
one-line constants change once role/person binding (1D open question) firms up.

## 2. Build phases

### Phase 5A — the R-item rail + queue
Types, gate checks (decision-ready, open-cap, resolution discipline), the queue fold
(open items deadline-ordered, oldest-basis first on ties), `mix cockpit.queue`
(deadline-ordered listing, packet refs resolvable) and `mix cockpit.decide <item_id>
approved|declined|returned_defect [--reason]` (typed confirmation — resolutions are
lax-direction). Retrofit seam: the harness's own R-shaped act (`SpecAdopted`) stays as
is — it predates the rail and is already one deliberate command; noted, not migrated.
**Acceptance [5A]:** an item missing any decision-ready element is unrepresentable; the
queue is a pure fold, `as_of:`-reproducible; flooding past the cap rejects; a resolution
closes exactly its item; `returned_defect` reopens nothing (the emitter must raise a
fresh, complete item).

### Phase 5B — the boards
`ε(π)` fold (escalations/acts per process — acts counted from each process's own decision
events), override/chronic counters, envelope heat (escalations per envelope version →
the widen-or-fix signal), B_op accounting per period with the structural-finding
emission, fold-health line (head age, last checkpoint age — single-node v0), and
`mix cockpit` composing queue + boards into one read. Veto feed: a labeled empty pane
backed by nothing (the seam, honestly displayed) until veto machinery exists.
**Acceptance [5B]:** every board number recomputes from the log; a B_op breach emits the
finding event exactly once per period; ε per process matches hand-computed ratios; the
no-surveillance map classifies every new query (`:system` — the cockpit reads
section/process aggregates and the operator's own queue, never member detail).

## 3. Open questions (owned here)

1. `cost(act_type)` model — declared minutes v0; measured (resolution timestamps) later.
2. The `operator` role key vs steward (see §1) — one-line change, governance timing.
3. Batch signing (10 §5 "where law permits") — not before a real H1 batch exists.
4. Veto-window machinery (δ per class, notification proof) — its own brief with the
   first H1 filing work.
5. Deadline re-derivation constants per class — with the first real deadline class.

## 4. Deliverables

`docs/phase5{a,b}_plan.md` per convention; `COCKPIT.md` normative (spec-shape, acceptance
mapped to tests); suite green, 1A–3B untouched; the D brief's §3.3 open question closed by
pointing its `EscalationRaised` at this rail. Corpus governs on conflict — flag it.

**Gate out:** the operator judges from one screen of derived truth, and the system can
prove — by replay — that every human signature sat exactly where the H-predicate said it
must, and nowhere else.
