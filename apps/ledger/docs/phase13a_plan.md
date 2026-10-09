# Phase 13A — Demo currency: the canonical scenario demonstrates the current promises

> **Status: COMPLETE** (2026-07-23). Acceptance **[13A]** passes: the
> result carries the upgraded verdicts all `:ok` — 6B baseline, 12B
> anchored self-contained verification, derived genesis matching the sim
> root, chain audit — plus the trimmed stake section with
> `dispatch_agrees: true` (1); the sim chapter's `governance` stream
> rides the bundle (8 streams) and `mix coop.demo` prints the new
> sections as a pure printer, exercised live (2); the 11A acceptance
> holds — sim boundary structural, two fresh runs agree on every
> invariant number (3); full suite green at 252 tests + 8 properties +
> 1 doctest, no substrate or query-surface change (4).

## Grounding

- `docs/phase11a_plan.md` (decisions 2–3: library-first, self-asserting;
  deferral scoped to NEW scenarios — keeping the canonical one current is
  maintenance of the existing scenario, not scenario growth).
- 12A/12B: anchored exports and in-band key derivation; 11B: the stake
  view. All demo-visible member promises.

## Design decisions (flagged)

1. **The sim world grows a trust chain.** `Sim.GateD` declares the
   genesis governance key (self-certified TOFU) and a checkpoint key
   before any governance-signed act, and returns both actors. Steward and
   author roles stay undeclared (bootstrap) — declaring them would only
   add ceremony the scenario doesn't exercise.
2. **The bundle section upgrades to the real promise.** The demo
   checkpoints the sim chapter, anchors the bundle, and verifies it
   SELF-CONTAINED — no key material passed in — then checks the derived
   genesis key against the sim's own governance key. Verdicts land in the
   result (`bundle_offline`, `bundle_anchored`, `genesis`, `chains`); the
   6B plain verification stays alongside as the baseline it is.
3. **The stake view joins the result — trimmed, invariant.** A compact
   stake section (membership state, capital balance, obligation count,
   and a `dispatch_agrees` flag pinning stake-view/demo-kit agreement)
   rather than the raw view: raw key ids are per-run random and would
   break the 11A run-to-run invariance acceptance, which this phase
   preserves.

## Acceptance [13A]

1. `Sim.Demo.run/1` returns the upgraded verdicts, all `:ok` — including
   self-contained anchored verification with the derived genesis matching
   the sim governance key — and the stake section with
   `dispatch_agrees: true`.
2. The bundle stream list now includes the sim chapter's `governance`
   stream; `mix coop.demo` prints the new sections (still a pure
   printer).
3. The 11A acceptance holds unchanged: non-sim chapters refused with
   nothing appended; two fresh-chapter runs agree on every
   scenario-invariant number.
4. Full suite green; no substrate/query-surface changes.

## Build steps

1. Add this plan and commit it before implementation.
2. `Sim.GateD`: genesis governance + checkpoint declarations; actors
   returned in the context.
3. `Sim.Demo`: checkpoint → anchor → `verify_anchored/1` (self-contained)
   with the genesis check; the trimmed stake section; verdicts in the
   result. `Mix.Tasks.Coop.Demo`: print the new sections.
4. Update `test/sim_demo_test.exs` expectations; full suite; commit only
   if green.

## Explicitly deferred

- Scenario growth (floor-cure, key-recovery, netting-consumption
  vignettes in the demo) — 11A's audience-need trigger, unchanged.
- Everything gated elsewhere (field, governance, spec, transport,
  08 §6) — unchanged.
