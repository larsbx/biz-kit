# Phase 11A — The demo/simulation entry point

> **Status: COMPLETE** (2026-07-21). Operator-directed: "We need an entry
> point for the demos and simulation." Acceptance **[11A]** passes:
> `Sim.Demo.run/1` runs the whole cycle on a fresh sim chapter and
> returns every number and verification verdict (1); non-sim chapter ids
> are refused with nothing appended (2); two fresh-chapter runs coexist
> on one store and agree on every scenario-invariant number (3);
> `mix coop.demo` is a pure printer over the returned map, exercised
> live (4); suite green at 243 tests + 8 properties + 1 doctest, no
> query-surface change (5). Discoverable from HARNESS.md's status line.
> Sim rules unchanged: synthetic actors only, the gate untouched,
> nothing produced is field evidence or a campaign asset.

## Grounding

- The 8A–9B sim arc (`Sim.GateD`, the tender/load/invoice rails, the R
  consumption contract, demo kit + guards) and the 9A obligation-rail
  integrity — every piece the entry point drives already exists and is
  test-covered; this phase only composes and reports.
- `docs/phase8d_plan.md`: the sim demo kit is a rehearsal of the folds,
  never a campaign asset (13 §6 stays gated on real books) — the entry
  point must keep that boundary structural, not conventional.

## Design decisions (flagged)

1. **Sim chapters are structural, not conventional.** The entry point
   refuses to run on any chapter id not prefixed `chapter-sim` — the one
   place a convention becomes a check, so the demo machinery can never be
   pointed at a real chapter by accident. Each run defaults to a fresh
   uniquely-suffixed sim chapter, so runs never collide and no store
   reset is needed (chapters are isolated; the log stays append-only).
2. **Library first, task second.** `CoopSubstrate.Sim.Demo.run/1` returns
   the full structured result (every number, every verification verdict)
   for tests and tooling; `mix coop.demo` is a thin printer over it. The
   printed report is derived from the returned map — no number exists
   only in IO.
3. **The demo asserts its own honesty.** The entry point re-verifies as
   it goes — offline bundle verification, chain audit, gate-recompute
   agreements — and the result carries those verdicts; a demo that
   doesn't verify isn't a demo (the 13 P2 spirit, in sim).

## Scenario (one run)

Sim gate(D) through the real pipeline → member envelope + rate terms →
the three fixture tenders routed (accept / decline / escalate) → the
escalation approved and consumed (9B) → the accepted tender dispatched
and tracked through both stops with detention → gate-recomputed invoice,
credit memo, dunning step → demo kit + guards (8D) → obligation rail:
ring, netting report, executed round, ring after (9A) → the carrier's
departure bundle exported and verified offline (6B) → chain audit.

## Acceptance [11A]

1. **One call runs the whole cycle.** `Sim.Demo.run/1` on a fresh default
   chapter returns the structured result: gate verdict, routing decisions,
   dwell, invoice, demo kit, guards, netting before/after, ring stats,
   bundle stream list, and the verification verdicts — all `:ok`/expected.
2. **The boundary is structural.** A non-`chapter-sim` chapter id is
   refused (`{:error, :not_a_sim_chapter}`); nothing is appended.
3. **Repeatable.** Two runs (fresh chapters) both succeed on the same
   store; numbers are equal run-to-run (the scenario is deterministic —
   ids and instants are fixed inside the run).
4. **The task is a printer.** `mix coop.demo` renders the returned map;
   it adds no computation.
5. Suite green; no query-surface change (sim modules drive commands and
   read through already-classified surfaces).

## Build steps

1. Add this plan and commit it before implementation.
2. `CoopSubstrate.Sim.Demo` (`lib/coop_substrate/sim/demo.ex`): the
   scenario as a library function returning the structured result;
   the sim-chapter guard.
3. `Mix.Tasks.Coop.Demo` (`lib/mix/tasks/coop.demo.ex`): print the
   report (`--chapter` override, still sim-guarded).
4. `test/sim_demo_test.exs` (acceptance 1–3); full suite; commit only
   if green.
5. Note the entry point in HARNESS.md's status line ("run the demos:
   `mix coop.demo`") so it is discoverable.

## Explicitly deferred

- The member stake view (the composed own-data read surface — the §8
  query-authn consumer; it was the alternative candidate this phase and
  remains next in line on direction).
- Demo scenarios beyond the canonical one (multi-member fleets,
  federation) — add when a demo audience needs them.
- Any rendered/report artifact beyond terminal output ([SECURITIES]/
  campaign surfaces stay counsel-governed and field-gated).
