# Phase 11B — The member stake view (the composed own-data surface)

> **Status: PLANNED** (2026-07-21). Scope is the consumer the briefs have
> named since 1B without building: `docs/handoff.md` §2.3 ("real-time
> queryable balance — the stake view will read this later") and
> SUBSTRATE.md §8 query-authn ("the requesting-member context … arrives
> with the first consumer (the stake view)"). Next in line per the 11A
> deferral list; operator said continue. Read-side only; no new event
> types; not blocked by `gate(D)`.

## Grounding

- `docs/handoff.md` §2.3 and SUBSTRATE.md §8 (query-authn: own-data
  classification is a contract awaiting its first consumer).
- The no-surveillance discipline (1C step 9): the view must be own-data
  by SHAPE — one subject argument, nothing reachable about anyone else
  except the member's own co-signed edges.
- Everything it composes already exists and is classified: `Capital`
  (balance, schedules), `Floor.cleared?`, `Throughput.value`, the
  obligation fold (bilateral edges the member co-signed),
  `Dispatch.demo_kit` (the member's own exhaust numbers).

## Design decisions (flagged)

1. **Composition, never recomputation.** `StakeView.view/3` calls the
   already-classified module queries and the gate fold — it derives no
   number of its own, so it can never drift from the modules (and a test
   pins the agreement). One call answers "what do I have?".
2. **Own-data by shape.** The single `member_id` argument is the subject
   AND the audience; the only cross-member content is the member's own
   bilateral obligation edges (each one dual-signed by them — their side
   of the 07 §5 sovereign edge). No filter, no lookup by counterparty.
3. **Requesting-member authn stays a transport concern.** There is no
   API server; every access is a library call. The view realizes the
   own-data *shape* the future middleware will enforce; signatures on
   requests arrive with the first transport (unchanged §8 position, now
   with its consumer existing).
4. **The floor instant is caller-supplied** (`at:`), like `Floor.cleared?`
   — no clock reads; without `at:` the floor/throughput section says so
   instead of guessing.

## Acceptance [11B]

1. **One call, whole stake.** For a member in the sim world:
   identity/current key, per-entity membership state and class, capital
   balance and redemption schedule, floor verdict and windowed throughput
   at `at:`, own dispatch numbers, and open obligation edges — in one
   map.
2. **Agreement.** Every number equals the underlying module's own answer
   (`Capital.balance/3`, `Floor.cleared?/4`, `Throughput.value`,
   `Dispatch.demo_kit/3`) — pinned by test.
3. **No cross-member reach.** A third member's view contains none of a
   pair's obligations; a pair member sees exactly their own edges; an
   unregistered member errors. Nothing in the returned map names a
   member other than the subject and their edge counterparties.
4. **Classified.** `view/2,3` classified `:own_data`; suite green.

## Build steps

1. Add this plan and commit it before implementation.
2. `CoopSubstrate.StakeView` (`lib/coop_substrate/stake_view.ex`).
3. No-surveillance entries; SUBSTRATE.md §8 query-authn note updated
   (the consumer now exists; middleware still awaits a transport).
4. `test/stake_view_test.exs` — the sim world for the full-stake case
   (agreement with `Sim.Demo`'s own numbers), a plain chapter for the
   reach/absence cases; full suite; commit only if green.

## Explicitly deferred

- Request signatures / requesting-member middleware (needs a transport).
- `as_of:` pinning of the whole view (compose when a dispute workflow
  needs it — same deferral as the 6B bundle pinning).
- Rendering (UI is a later brief; this is the read model it will call).
