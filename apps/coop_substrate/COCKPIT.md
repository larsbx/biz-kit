# COCKPIT.md — The R-Queue + Boards (Normative)

Status: **complete** (Phases 5A–5B, 2026-07-11; plans under `docs/phase5{a,b}_plan.md`,
brief at `docs/handoff_cockpit.md`). Normative for the cockpit; the outer authority is
`docs/corpus/10_AUTONOMY.md` §5–§6 — on conflict the corpus governs, flagged. Everything
rides the substrate: signed events through the append gate, pure folds, constants
declared before first evaluation.

## §0 Spine

```
R item     unrepresentable unless decision-ready: packet refs, recommendation, bounds,
           compensation path, deadline+basis (missing fields fail at envelope
           construction; hollow fields at the gate) — the operator judges, never
           assembles (10 P10)
queue      = open items, a pure fold, {deadline_ms, item_id}-ordered, as_of-reproducible
resolution = a signed act (approved | declined | returned_defect), closing exactly its
           item once; approval AUTHORIZES — consuming domains append their own
           consequent events referencing it (provenance ends in the human, 08 §1)
flooding   structurally capped per process (cockpit/open_cap, fails closed undeclared)
boards     = pure folds + declared constants + the caller's clock; absent numbers SAY SO
B_op       = accounting, never enforcement: breach ⇒ StructuralFindingRaised, exactly
           once per (kind, period) — a design finding, never staffing (10 P9)
```

## 1. Surfaces

| Surface | What | Notes |
|---|---|---|
| `EscalationRaised/Resolved` | the rail | steward-signed (dedicated `operator` role: flagged one-line future change); `returned_defect` terminal for the id |
| `StructuralFindingRaised` | guard findings | closed kinds (`b_op_breach` live; `epsilon_breach`/`chronic_override` reserved); unique id AND unique (kind, period) |
| `Cockpit.queue/2` | deadline-ordered open items | `:system`-classed |
| `Cockpit.boards/3` | queue summary · per-process guard board (raised/open/verdicts, **approval rate** — chronic approval = bound too tight, chronic decline = agent logic wrong, 10 §5) · **act heat** per (process, act_type) · B_op pane · fold health · veto seam | caller supplies `now_ms`; everything else is fold |
| `Ops.escalate/decide/guard_sweep` + `mix cockpit{,.queue,.decide,.sweep}` | the CLI | `cockpit.decide` behind typed confirmation (lax-direction) |

Constants (04 §9, via `CharterConstantDeclared`): `cockpit/open_cap` (validity — fails
closed) · `cockpit/b_op`, `cockpit/period_ms`, `cockpit/cost_default` (accounting —
unconfigured pane, never a gate).

## 2. Flagged limits & corrections (each logged in its phase plan)

- **Basis verification (5A correction):** `basis_ref` is required and typed; its
  *resolution* and mechanical deadline re-derivation land with the first real deadline
  class — intra-batch envelopes have no stable hash pre-assignment, and the gate fold
  indexes domain state, not every event hash.
- **Tie order (5A correction):** `item_id` on equal deadlines (basis time untracked).
- **ε(π) has no denominator yet:** true escalations/acts awaits domain act streams
  (D build 4D); the board shows counts + approval rate and says so.
- **Checkpoint age absent from fold health:** checkpoints deliberately live outside the
  log; aging them needs a marker event or blob-path convention — an operating decision.
- **Costing:** flat `cost_default` minutes per resolved item; per-act-type and measured
  costing future.
- **Veto feed:** an honest empty seam until veto-eligible acts (H1/POA) exist.

## 3. Acceptance (brief items → evidence)

- **[5A]** decision-ready unrepresentable otherwise; pure as_of-reproducible queue;
  flooding capped (fails closed undeclared); close-once; `returned_defect` finality —
  `cockpit_queue_test`.
- **[5B]** board arithmetic recomputes (identity on re-call); period-boundary attribution
  by signed resolution timestamps; breach findings exactly-once per (kind, period) with
  the sweep idempotent by rejection; unconfigured pane; accounting-never-enforcement —
  `cockpit_boards_test`.

## 4. Gate out

The operator judges from one screen of derived truth, and replay proves every human
signature sat exactly where the H-predicate said it must — and nowhere else. When the
D build lands, its out-of-envelope escalations ride this rail unchanged; when its act
streams exist, ε(π) gets its denominator; when veto-eligible acts exist, the empty pane
fills. Nothing needs rework for any of that — only data.
