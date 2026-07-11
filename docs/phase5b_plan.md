# Phase 5B — The boards

> **Status: IN PROGRESS** (2026-07-11). Scope is the cockpit brief's Phase 5B, its final
> phase; acceptance = brief items **[5B]**. Gate honored: [5A] passed before this began.
> Normative outer authority: corpus 10 §5 (the five panes), P9 (breach = design finding,
> never staffing), 08 §5 (guards — v0 counters, estimators accrete).

## §0 Spine

```
boards      = pure folds over the rail + constants; every number recomputes from the log
heat        = escalations per (process, act_type) + approval rate — the widen-∨-fix
              signal, v0 analog of envelope heat (envelopes arrive with the D build)
B_op        = accounting + a structural-finding EVENT on breach, exactly once per period
              — never enforcement, never staffing (10 P9)
ε(π)        = escalations/acts: the DENOMINATOR does not exist until domains emit
              per-process act streams (D build 4D) — reported as counts now, flagged
```

## Settled decisions (honest v0 scoping — the repo has no envelopes or domain acts yet)

- **Guard board v0** = per-process counts from the rail itself: raised / open / resolved
  by verdict / **approval rate** — chronic approval is the bound-too-tight signal,
  chronic decline the agent-logic-wrong signal (10 §5's "chronic overrides mean the
  automated logic or the human is structurally wrong", computable today). True `ε(π)`
  lands with the D build's act streams — **flagged**, not faked.
- **Envelope heat v0** = escalations per `(process, act_type)` — the same widen-∨-fix
  read keyed by act type until envelope versions exist to key by. The pane renames
  itself honestly ("act heat").
- **B_op accounting**: constants `cockpit/b_op` (minutes per period), `cockpit/period_ms`,
  `cockpit/cost_default` (minutes per resolved item — the brief's per-act-type costing
  stays flagged future). `spent(period) = resolved items in period × cost_default`
  (resolution time = the signed envelope timestamp, now stored in the fold). Undeclared
  constants ⇒ the pane reports *unconfigured* — accounting is reporting, never a gate
  (P9), so it does not fail closed like validity constants do.
- **Breach emits `StructuralFindingRaised{finding_id, kind, period_ref, note?}`** —
  steward-signed via `Ops.guard_sweep/1` (folds cannot sign; the sweep is an operator/
  cron act that computes and appends). Gate: closed kind set (`b_op_breach` now;
  `epsilon_breach`/`chronic_override` reserved), unique `finding_id`, and **unique
  `(kind, period_ref)`** — exactly-once per period is structural, so a re-run sweep is
  idempotent by rejection.
- **Fold health v0** = head seq + last-event timestamp + age against the caller's clock
  (presentation, not fold state). Last-checkpoint age is **flagged out**: checkpoints
  deliberately live outside the log, so aging them needs either a marker event or a
  blob-path convention — a decision for when someone actually operates on it.
- **Veto feed** = a labeled empty pane, verbatim from the brief.
- **Surfaces**: `Cockpit.boards/2` (chapter, `now_ms:` — the caller supplies the clock;
  everything else is fold), `Ops.guard_sweep/1`, `mix cockpit` (queue summary + all
  panes), `mix cockpit.sweep`. `COCKPIT.md` closes the brief.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. `StructuralFindingRaised` type + gate (closed kinds, id + `(kind, period_ref)`
   uniqueness) + fold additions (findings; resolution verdict/timestamp on items).
3. `Cockpit.boards/2`; `Ops.guard_sweep/1`; `mix cockpit` + `mix cockpit.sweep`.
4. Tests: board arithmetic against hand-built rails (counts, approval rate, act heat);
   B_op spent/breach math across period boundaries; sweep appends exactly once and is
   idempotent by rejection; unconfigured pane; fold-health line; `mix cockpit` smoke
   incl. the veto seam line.
5. `COCKPIT.md` (normative, spec-shape, acceptance [5A]+[5B] mapped to tests; the 5A
   corrections and the ε/checkpoint-age flags recorded); acceptance recorded; status
   flip — commit; brief closed.

## Properties

```
P1  every board number recomputes from (log, declared constants, caller clock)
P2  breach findings are exactly-once per (kind, period): duplicates unrepresentable,
    so the sweep is idempotent by rejection
P3  B_op is accounting: undeclared ⇒ unconfigured pane; breach ⇒ finding event; nothing
    is ever blocked or staffed by it (10 P9)
P4  heat and approval rates match hand-computed ratios over the same events
P5  the ε denominator and checkpoint age are absent AND SAY SO — no fabricated numbers
```

## Adversarial

Sweep re-run in the same period (rejected duplicate — idempotence) · a finding forged for
a future period (period_ref is arithmetic over declared constants; a mismatched claim is
auditable on replay — flagged as review, not gate, v0) · cost gaming by resolving items
just across a period boundary (visible: resolution timestamps are signed) · a board
number that cannot be recomputed (P1 test recomputes them all).

**Gate out:** with [5B] green the cockpit brief closes — the operator judges from one
screen of derived truth.
