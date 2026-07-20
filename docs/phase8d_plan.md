# Phase 8D — Dispatch-D under simulation: demo kit + guards v0 (the 4D slice)

> **Status: PLANNED** (2026-07-20). Final sim slice under the 8A
> authorization (operator-directed: all three remaining sim slices). Same
> rules: real machinery, untouched gate, nothing simulated is field
> evidence — **the demo kit compiled from a sim chapter is a rehearsal of
> the folds, never a campaign asset** (13 §6 stays gated on the first
> hub's real books).

## Grounding

- `docs/handoff_dispatch_d.md` §2 Phase 4D: open-book, hours-returned, and
  detention-recovered folds (13 §3); stake-view seam = the existing
  `Capital` queries; guard counters v0 (escalation rate ε per process,
  override counts — 10 §5's design lever, **surfaced not yet estimated**).
  §0.8: the demo compiles from FULL folds — selective compilation
  unrepresentable, recompile-and-compare discipline.
- 8A–8C machinery: tenders (decisions + escalations), loads (status
  trail, dwell), invoices (linehaul/detention lines, credit memos).
- 10 §4.1: check calls are deleted, not automated — "hours returned" v0 is
  the count of status events ingested instead of calls made, times a
  declared minutes-per-call constant (PLACEHOLDER, charter-declarable),
  reported as minutes so no estimate hides in a unit conversion.

## Acceptance [8D]

1. **Every demo number recompiles from the full stream.**
   `Dispatch.demo_kit/3` is a pure fold over the carrier's whole exhaust:
   tender counts by outcome, loads dispatched/completed, open-book
   invoiced/credited/net, detention-invoiced minutes and value, statuses
   ingested and minutes-returned (declared constant × count; absent when
   undeclared — fails closed to "not estimable", never a guess). The
   function takes no filter beyond (chapter, member, entity): selective
   compilation is unrepresentable by shape. Recompilation after appender
   restart is equal.
2. **ε(π) is computable per process.** `Dispatch.guards/1` reports, per
   process, decisions, escalations raised, and the escalation rate in
   basis points — counters surfaced, nothing estimated, no member detail.
3. **Classification.** `demo_kit/3` own_data; `guards/1` system (process
   counters only). No new event types — this slice is read-side only.

## Build steps

1. Add this plan and commit before implementation.
2. `Constants.minutes_per_check_call/0` PLACEHOLDER note — v0 reads the
   charter constant `dispatch/minutes_per_check_call` from the log and
   reports `nil` when undeclared (fails closed; no code fallback).
3. `Dispatch.demo_kit/3` and `Dispatch.guards/1` as pure folds over the
   existing projection state; no projection changes, no registry changes.
4. No-surveillance entries; `test/dispatch_demo_test.exs` on the sim
   world; full suite; commit only if green.

## Explicitly deferred

- ε estimation, thresholds, and structural-finding wiring (10 §5 — the 5B
  boards already own breach findings; this slice only surfaces dispatch
  counters).
- Rendered demo assets (open-book statements as artifacts) — the numbers
  are the deliverable here; rendering belongs to the real 4D with real
  books.
- Override counts (no override event type exists yet in the dispatch rail
  — an override IS an R resolution today, visible in the 5A queue).
