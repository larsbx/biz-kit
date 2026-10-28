# Pooled Clearing — many-party contractual brokerage routing

`BarterCore.PooledClearing.optimize/3` matches any number of independently
operated supplier-members' multi-good needs and supplies. Exact integer
resource quantities may split across providers and recipients. Each exact
(code, unit) has a separate deterministic integer maximum-flow solution,
subject to per-member supply and demand and no self-delivery.

This replaces an arbitrary cycle-length limit with work-budgeted polynomial
matching; unlike closed-cycle matching, pooled allocation may contain
incomplete and economically unbalanced exchanges. Such allocations **cannot
be executed** without an explicit all-member contract that settles what each
party gives and receives and contains remedies for any shortfall. The first
mathematical optimum is only the **maximum physical units of each separate
resource**, not total barter value or welfare.

`BarterCore.PooledBrokerage.draft/3` creates an all-member charter/plan
fingerprint. `pre_delivery_preview/3` checks the supplied member evidence
reference shapes and renders unadmitted proposed deliveries. It does not
incorporate a company, authenticate a signature, reserve inventory, admit
ledger entries, give a mediator title to goods or settle consideration.

Run `cd apps/barter_core && mix test` on Elixir 1.19 / OTP 27.

See [ADR](../../docs/architecture/2026-10-26-pooled-brokerage-clearing.md)
and [tracking issue #131](https://github.com/larsbx/biz-kit/issues/131).
