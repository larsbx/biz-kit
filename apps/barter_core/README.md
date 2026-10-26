# BarterCore — optimized federated exchange and contractual broker previews

A dependency-free Elixir clearing kernel for the federated biz-kit marketplace.
The market can publish both needs and supplies. Any number of independent
participating entities may contract into a temporary, member-governed
brokerage/consortium to coordinate an optimized multi-party exchange.

The first exact optimizer uses Hungarian assignment to maximize the number of
**fulfilled indivisible intent slots**, not monetary value, welfare or
fairness. A business can advertise multiple slots. It may obtain goods from
one supplier and provide goods to another; separate cycles can be cleared
in one round. No arbitrary four-entity limit applies. A work budget limits
CPU rather than exchange topology. Each slot has exact code, unit, positive
integer quantity, owner, revision and expiry. No FX or cross-unit conversion.

```elixir
{:ok, plan} = BarterCore.optimize(intents, now)
# plan.cycles, plan.matched_intents, plan.unmatched, plan.terms_hash

{:ok, contract} =
  BarterCore.Brokerage.draft(plan, authorized_charter, now)

{:ok, preview} =
  BarterCore.Brokerage.pre_delivery_preview(contract, evidence_refs, now)
# preview: unadmitted obligations, NOT an executed contract or company
```

The brokerage draft binds charter ID, digest, version, term, authority,
matched members and exact optimized plan in one agreement fingerprint.
All members must explicitly sign after reviewing the same terms. These
pure functions check only the **shape** and digest of supplied evidence
references, not real signatures. Business entity registration, actual
agency authority, inventory reservations, ledger admission, payment,
fulfillment and legal validity remain external gates.

The first charter policy delegates matching and reconciliation only;
original suppliers retain title until authorized transfer to recipients.
A real corporation is **not** created automatically. There is no central
ledger or network-wide atomic transaction. Individual installations
retain authorization and accounting, and independently reconcile
contingent obligations and proof of actual delivery.

Integration with public ActivityPub/iroh discovery, member agreements,
InventoryCore, FulfillmentCore/Dispatch and local accounting is follow-on
work, not implemented in this kernel. For multi-item bundles, stock
splitting, time windows, legal/tax rules, incentives, credits or different
optimization objectives, define a separate optimization contract and its
bounded/verified algorithms rather than treating the slot assignment as
globally optimal for all barter.

Run `cd apps/barter_core && mix test` under Elixir 1.19 / OTP 27.

See [the updated ADR](../../docs/architecture/2026-10-26-direct-barter.md)
and [issue #131](https://github.com/larsbx/biz-kit/issues/131).
