# Phase 10A — Floor enforcement: evidenced transitions and the cure window

> **Status: COMPLETE** (2026-07-21). Scope was the SUBSTRATE.md §8 item
> carried since 1C. Acceptance **[10A]** passes: cure starts only on the
> member's own failing evaluation, ids one-shot (1); the exit fails
> closed without `floor/cure_window_ms` and opens only citing a failing
> evaluation at or beyond the window, closing the direct
> member→floor_exited path (2); recovery needs a passing evaluation
> after the cure anchor and later rounds anchor fresh (3); hardship
> symmetry regression-pinned (4); no new queries, suite green at 237
> tests + 8 properties + 1 doctest (5). One flagged deviation from the
> build sketch: evaluations are keyed and cited by a new required
> `evaluation_id`, NOT by event hash — the gate fold must stay valid
> over unassigned envelopes (its documented invariant; `event_hash`
> covers log-assigned chain fields), and every gate-resolved reference
> in the system is a payload id. The clause-grouping compiler warnings
> in the projection and validity modules were regrouped away (no
> behavior change), per step 6.

## Grounding

- `SUBSTRATE.md` §13.1 (cure/hardship lifecycle; hardship suspends
  evaluation symmetrically), §13.4, §8 (the enforcement item verbatim);
  the registry's own 1C note on `MembershipFloorExited`:
  "evaluation_ref will point at the floor-evaluation event once that
  exists."
- `docs/handoff.md` §2.4: the floor is generous, windowed, per class —
  and exits from it must be evidence, not steward fiat.
- Existing machinery: `FloorEvaluationRecorded` (steward attestation
  citing rule/window/value), event hashes as the standard reference
  (`:hash` fields, the CorrectionRecorded pattern), the 7A precedent for
  pre-genesis registry amendment, fail-closed undeclared constants.

## Design decisions (flagged)

1. **Evaluations gain their instant.** `FloorEvaluationRecorded` gains a
   required `at_ms` (the evaluation instant the verdict is about — the
   same caller-supplied `at:` the `Floor.cleared?/4` query takes). An
   evaluation without its instant is not reproducible and cannot anchor a
   window. Pre-genesis in-place amendment (the 7A rule: §1.3 governs
   after first real adoption).
2. **Floor transitions are evidenced, not asserted.** `evaluation_ref`
   becomes REQUIRED on all three floor transitions and is checked against
   the gate's own fold of evaluations (keyed by event hash):
   - `FloorCureStarted` — a failing (`cleared: false`) evaluation for the
     same (member, entity): cure begins on evidence.
   - `FloorCureCleared` — a passing evaluation with `at_ms` after the
     cure began: recovery is evidence too.
   - `MembershipFloorExited` — a failing evaluation with `at_ms` at or
     beyond `cure_start + floor/cure_window_ms`: the member stayed below
     the floor through the whole declared window. No clock is read
     anywhere — the window is arithmetic over signed `at_ms` values.
3. **The exit fails closed on the undeclared constant.** While a chapter
   has not declared `floor/cure_window_ms`, `MembershipFloorExited` is
   unrepresentable (member-protective: entering cure and clearing it
   need no constant; only the harmful act does). This is the harness
   fail-closed doctrine, deliberately NOT bootstrap-then-enforce —
   unlike 9A's exposure caps, there is no pre-existing rail to keep
   working, and the default must favor the member.
4. **Evaluation content stays an attestation.** The gate does not
   recompute `value`/`cleared` against the throughput fold — that would
   put a second projection in the gate state, and evaluation semantics
   belong to the absent throughput_and_floor spec. Deferred, flagged;
   the attestation is auditable offline by replay today.

## Acceptance [10A]

1. **Cure on evidence.** `FloorCureStarted` without an `evaluation_ref`,
   with a passing evaluation, or with another member's evaluation is
   rejected; with a failing evaluation it lands and the cure anchor is
   that evaluation's `at_ms`.
2. **Exit only through the window.** With `floor/cure_window_ms`
   declared, `MembershipFloorExited` is representable only citing a
   failing evaluation at or beyond the window's end; earlier failing
   evaluations, passing evaluations, and an undeclared constant all
   reject before persistence. The lifecycle still only permits the exit
   from `in_cure`.
3. **Recovery on evidence.** `FloorCureCleared` requires a passing
   evaluation after the cure anchor; the member returns to `member` and
   a later cure round starts fresh.
4. **Hardship stays symmetric** (regression-pinned): evaluations remain
   unrepresentable in hardship, so no cure/exit evidence can even be
   produced against a hardship member.
5. **No new queries; suite green.** The no-surveillance surface is
   unchanged; existing floor lifecycle tests updated for the new
   required fields; full suite green.

## Build steps

1. Add this plan and commit it before implementation.
2. Registry: `at_ms` required on `FloorEvaluationRecorded`;
   `evaluation_ref` required on `FloorCureStarted`, `FloorCureCleared`,
   `MembershipFloorExited`.
3. Projection: fold evaluations by event hash
   (`floor_evaluations`); anchor cures (`floor_cures`) at the cited
   evaluation's `at_ms`; clear the anchor on cure exit.
4. Gate: the three evidence checks + the fail-closed window arithmetic,
   layered onto the existing lifecycle check.
5. Tests: `test/floor_enforcement_test.exs` (acceptance 1–4) plus
   fixture updates in the existing floor/lifecycle tests.
6. SUBSTRATE.md §13.1 note + §8 item resolved; full suite; commit only
   if green. Fold in the outstanding clause-grouping compiler warnings
   in `membership.ex`/`validity.ex` (regroup only — no behavior change).

## Explicitly deferred

- Evaluation cadence (who runs evaluations, how often — operational/
  cockpit; the mechanism now enforces everything a cadence produces).
- Gate-recomputed evaluation content (decision 4).
- Re-entry semantics after `floor_exited` (§8 re-joining, governance).
- Per-class window values (one chapter-wide constant in v0; per-class
  differentiation arrives with the throughput_and_floor spec).
