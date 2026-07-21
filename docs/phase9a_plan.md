# Phase 9A — Obligation-rail integrity: netting execution, exposure caps, ring visibility

> **Status: PLANNED** (2026-07-21). Scope is the anti-gaming accretion
> SUBSTRATE.md §8 has carried since 1C ("`NettingExecuted` batch
> discharge, exposure caps (05 P7) as gate checks, circular/self-dealing
> netting detection") — the oldest stated-but-unbuilt mechanism after 8D.
> Not blocked by `gate(D)`; no crypto (deterministic arithmetic and graph
> checks at the plain rung — 08 §6 escalation stays untriggered; the only
> cross-member surface is a bare aggregate).

## Grounding

- `docs/corpus/05_FINANCE.md` §1.2 (netting first — period-end set-off;
  "netting is a computation over this rail; settlement is evidence about
  it"), P5 (identical denomination only), P7 ("exposure ≤ declared caps,
  per-funder and per-borrower"), P10 (all of it pure functions of the
  log); §2 exposure bullet ("declared, structural; chapter-level exposure
  visible only as a privacy-preserving aggregate").
- `docs/handoff.md` §2.4: "circular/self-dealing netting, per-counterparty
  cap … deterministic graph/aggregate checks over the (privately-held)
  transaction graph."
- Existing machinery: `Finance.compute/3` (the pure set-off core — the
  gate will recompute it, the 8A decision pattern), the dual-signed
  obligation rail with `check_party_key`, the 1D bootstrap-then-enforce
  precedent for undeclared constraints, self-obligation already
  unrepresentable.

## Design decisions (flagged)

1. **Netting is executed bilaterally, per denomination.**
   `NettingExecuted` is dual-signed by both pair members (roles
   `party_a`/`party_b`, `party_a < party_b` lexically so the pair has one
   representation) and cites the full report for that denomination
   (gross both ways, set-off, net). The gate recomputes
   `Finance.compute/3` and demands equality — a stale or tampered report
   is unrepresentable, and a round with zero set-off is rejected.
   Effect: every open like-denominated pair obligation closes atomically;
   a non-nil residual opens as a fresh obligation (`residual_obligation_id`
   in the payload, required exactly when the net is non-nil) whose dual
   signature IS the netting event's.
2. **Exposure caps are bootstrap-then-enforce** (the 1D role-key
   precedent, NOT the fail-closed cockpit pattern): the rail predates the
   caps and must keep working; once a chapter declares
   `finance/borrower_cap_minor` (per-debtor aggregate open exposure) or
   `finance/funder_cap_minor` (per-creditor concentration), every new
   `ObligationRecorded` beyond the declared cap is rejected. 05 P7 calls
   the caps declared-structural — declaration is what creates the
   constraint.
3. **Ring visibility is an aggregate, not a roster.** Circular structures
   (A→B→…→A among open obligations) are reported by
   `Finance.ring_stats/2` as counts and gross value only — no member ids
   cross the boundary (05 §2's privacy-preserving-aggregate rule; the
   no-surveillance classes admit nothing between bilateral and
   aggregate). Blocking cycles at the gate would outlaw ordinary
   commerce; naming members would be surveillance. What a chapter does
   with a nonzero ring count is an R/governance act, not mechanism.

## Acceptance [9A]

1. **Netting executes or is unrepresentable.** A `NettingExecuted` equal
   to the recomputed report closes every open pair obligation in its
   denomination and opens exactly the residual; tampered figures, wrong
   denomination, unsorted pair, zero set-off, and a missing/superfluous
   residual id are all rejected before persistence. Other denominations
   and other pairs are untouched. Post-execution, `Finance.netting/3`
   for the pair shows only the residual.
2. **Caps bind on declaration.** Before declaration the rail is
   unbounded (bootstrap, flagged); after `finance/borrower_cap_minor` /
   `finance/funder_cap_minor` declaration, an `ObligationRecorded` that
   would push the debtor's aggregate (or creditor's concentration) past
   the cap is rejected; netting execution reduces exposure and re-opens
   headroom.
3. **Rings are visible as aggregates.** `ring_stats/2` reports
   `%{rings, gross_minor}` over open obligations (per denomination),
   zero on a ring-free rail, nonzero when a cycle exists, and never
   returns a member id. Self-dealing stays unrepresentable
   (`:self_obligation`, already enforced — regression-pinned here).
4. **Purity.** Netting reports, cap checks, and ring stats are pure
   functions of the log (05 P10): recomputation after an appender
   restart is equal; chains verify.
5. **Classification.** `ring_stats/2` classified `:aggregate`;
   `NettingExecuted` streams are `:bilateral` like the rest of the rail.

## Build steps

1. Add this plan and commit it before implementation.
2. Registry: `NettingExecuted` (roles `party_a`/`party_b`, bilateral,
   stream `netting/<party_a>/<party_b>`), payload citing the report and
   the optional residual id.
3. Gate: recompute-and-compare via `Finance.compute/3`; party-key checks;
   pair-order and residual-id shape checks; exposure-cap checks on
   `ObligationRecorded` (bootstrap-then-enforce from the two charter
   constants).
4. Projection: `NettingExecuted` closes the pair's open obligations in
   that denomination and opens the residual.
5. `Finance.ring_stats/2` (cycle detection over the open-obligation graph
   per denomination, aggregate output only) + no-surveillance entries.
6. `test/netting_execution_test.exs`; SUBSTRATE.md §8 item resolved and
   §13.3 note updated; full suite; commit only if green.

## Explicitly deferred

- Witness attestation on netting rounds (05 §1.2 names it; the dual
  signature is the v0 witness surface).
- Per-counterparty *throughput* caps (needs the absent
  throughput_and_floor spec — §8's rail-settlement placeholder).
- Any enforcement consequence of a nonzero ring count (R/governance, not
  mechanism; the 5B structural-finding rail is the natural consumer).
- Cross-chapter (federation) netting — §8 federation scoping.
