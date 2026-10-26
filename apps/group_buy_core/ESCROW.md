# Escrow-backed group buying (pure evidence model)

`GroupBuyCore.BindingRound` makes a signed conditional purchase pledge
**binding at the seller's admitted minimum volume**, without another buyer
election. `GroupBuyCore.Escrow` attaches evidence that each participant's
money is actually protected by an **independently authorized third-party
escrow provider**.

A buyer's pledge can have protected funds before the threshold. The
seller-home must verify authenticated member consent, seller offer/capacity
and custodian confirmation. Until the minimum, no goods or payment are due
to the seller. At threshold, binding activates automatically, but an
escrow-backed activation is only **ready** when all bound pledges pass
`Escrow.coverage/3` from verified provider evidence.

Settlement is **delivery-conditional**. After independently verified
fulfillment, a custodian may pay the seller the exact current discounted
price and return any surplus to the buyer if a deeper volume tier was
unlocked. If minimum never occurs before campaign expiry, the custodian
returns protected funds to buyers; disputes freeze ordinary release and
require lawful external resolution.

```elixir
{:ok, escrow} = GroupBuyCore.Escrow.new(member_only_offer, now)
# Seller-home verifies provider evidence before local durable admission.
{:ok, escrow, :accepted} =
  GroupBuyCore.Escrow.apply(
    escrow, binding_round,
    {:custody_provider, provider_id},
    verified_funding_event, now
  )
{:ok, secured} = GroupBuyCore.Escrow.coverage(escrow, binding_round, now)
# Computes readiness ONLY. No money has moved via biz-kit.
```

The library never takes custody, signs a contract, checks external
provider signatures itself, makes payment requests, registers a company,
reserves stock or claims legal enforceability. Names such as
`:hold_confirmed` mean that the *trusted host* has separately obtained
and authenticated the external custodian's evidence. Just passing a string
does NOT prove it.

See [escrow ADR](../../docs/architecture/2026-10-26-group-buy-external-escrow.md).
