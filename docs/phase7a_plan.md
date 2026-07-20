# Phase 7A — Redemption enforcement (the gate evaluates the capital fold)

> **Status: PLANNED** (2026-07-20). Scope is the SUBSTRATE.md §8 item
> "Redemption enforcement (1B → later)": annual-cap and payment-vs-balance
> checks at the append gate. Dangling since 1B (§11.5: "No payout engine,
> cap enforcement, or eligibility logic exists yet"). Not blocked by
> `gate(D)`; no crypto involved (deterministic arithmetic over the gate's
> own fold — 08 §6 escalation stays untriggered).

## Grounding

- `docs/handoff.md` §2.3: redemption schedule support — "multi-year payout,
  sinking-fund accounting, annual cap, FIFO, death-to-estate … the account
  must be redeemable by every exit type."
- `docs/corpus/04_ENTITIES.md` §3: redemption at declared terms, FIFO
  queue, "exit without forfeiture" — a payment engine that can silently
  overdraw a member's account is a forfeiture surface.
- `SUBSTRATE.md` §11.5 (the data structures already carry `years`,
  `annual_cap_minor`, `method: "fifo"`), §8 (the enforcement item verbatim).
- Existing code: eligibility and schedule-open checks already gate
  `RedemptionScheduleOpened`/`RedemptionPaid` (`Protocol.Validity`); the
  accrual math is a shared pure module (`Capital.Rules.LinearV1.credit/3`);
  the gate state (`Projections.Membership`) already folds `active_rules`
  and `schedules`.

## Design decisions (flagged)

1. **The cap's time dimension is the schedule year, not the calendar.**
   `RedemptionPaid` gains a required `year_index` (int, 0-based): the
   payout year within the schedule it draws against. The gate enforces
   `0 ≤ year_index < years` and cumulative payments per
   `(schedule, year_index)` ≤ `annual_cap_minor`. This bounds total payout
   at `years × annual_cap_minor` deterministically, with no wall-clock in
   any fold (the §1.2 determinism discipline). Mapping schedule years to
   calendar dates is operational cadence — charter/workflow, not mechanism.
2. **Pre-genesis schema amendment, in place.** Adding a required field to
   `RedemptionPaid` amends the compile-time registry rather than declaring
   a new `schema_version`. §1.3's evolution rule protects deployed logs;
   none exists — `gate(D)` has never passed and every store is synthetic.
   Flagged: after first real adoption this shortcut is closed and §1.3
   governs.
3. **Balance lives in the gate's own fold.** `Projections.Membership`
   tracks `credited − redeemed` per (chapter, member, entity), crediting
   via the same `Capital.Rules` module the capital projection uses — one
   accrual implementation, two folds that must agree (and a test says so).
   The gate does not reach into the capital projection.

## Acceptance [7A]

1. **Payment-vs-balance.** A `RedemptionPaid` whose amount exceeds the
   member's remaining balance (credited − already redeemed, under the
   in-log rule versions) is rejected *before persistence*; chains verify
   after the rejection. Exact-balance payment is accepted (exit without
   forfeiture: the member can always be paid out in full).
2. **Annual cap.** Cumulative payments within one `year_index` never
   exceed `annual_cap_minor`; a payment that would cross it is rejected;
   `year_index` outside `0..years-1` is rejected. A compliant multi-year
   sequence (including death-to-estate accounts) appends cleanly.
3. **Fold agreement.** The gate's balance equals `Capital.balance/3` at
   every step of an accepted sequence — including across an accrual-rule
   change (forward-only application on both sides).
4. **No regression.** The FIFO consumption, sinking-fund draw, export
   bundle, and no-surveillance surfaces are untouched; the full suite
   stays green.

## Build steps

1. Add this plan and commit it before implementation.
2. Registry: add required `"year_index" => :int` to `RedemptionPaid`.
3. Gate state: fold patronage credits and redemption debits into
   `Projections.Membership` (reusing `Capital.Rules`); record per-year
   cumulative payments on the schedule entry.
4. Gate checks: extend the `RedemptionPaid` type_check with balance and
   cap conditions; update the `Validity` moduledoc line that currently
   defers them.
5. Tests: extend the redemption coverage in `test/capital_accounts_test.exs`
   (overdraw rejected, exact balance accepted, cap boundary, bad
   `year_index`, fold agreement across a rule change); adjust existing
   fixtures for the new required field.
6. Update SUBSTRATE.md: §11.5 workflow note, §8 enforcement item, and the
   §12 acceptance table pointer.
7. Run the focused tests and the full suite. Commit only if green.

## Explicitly deferred

- **Sinking-fund overdraw gating.** A draw may exceed the entity's fund
  balance today; the projection shows the negative number. Whether the
  gate blocks illiquid payouts is a liquidity-policy question (04 §3
  "declared liquidity gates") for the charter, not this mechanism.
- **Schedule completion / `:redeemed` terminal account status.** Today an
  account stays `:in_redemption` after full payout; a closure event is
  workflow that can wait for the first real departure.
- **Calendar cadence** for schedule years (operational; see decision 1).
- **Re-joining after a terminal membership state** (§8, governance).
