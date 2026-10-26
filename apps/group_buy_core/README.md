# GroupBuyCore — collective purchasing without compulsory middlemen

**Current rule:** [Member pledges cover volume; only then is the discounted
purchase option displayed](../../docs/architecture/2026-10-26-group-buy-pledge-purchase-gate.md).
A pledge is allowed and counts toward a posted minimum. **Advance purchase
contracts are not required** merely to unlock that purchase choice.
All prices and rate ladders remain **members-only**, and ordinary cash
checkout is independent of the group-volume gate. Neither a pledge nor an
available option is payment, reserved stock or a binding sale.

Independent sellers can offer a group-buy campaign that attracts many
buyers across biz-kit's federated marketplace. Each buyer maintains an
**ordinary cash-payment alternative**. A seller can voluntarily incentivize
collective purchases using explicitly funded, decreasing volume price tiers.
Joining a campaign is optional and the pure kernel never collects money,
reserves stock, establishes a brokerage or accepts a purchase.

`GroupBuyCore.quote(offer, pledges, now)` computes a deterministic private
preview from the source-bound seller terms and revision-bound buyer pledges.
It excludes expired pledges, rejects oversubscription and incompatible price
caps, and shows the group tier only when sufficient active pledges cover its minimum. Every buyer gets
exact integer cash and group-price totals and savings. The entire candidate
is bound to an immutable digest; no cross-currency arithmetic occurs.

`GroupBuyCore.purchase_option(quote, buyer, now)` returns a private individual
purchase-choice preview only while the pledges still cover the minimum;
no payment or reservation occurs. The optional
`GroupBuyCore.commitment_preview(quote, seller_consent, buyer_consents, now)`
requires matching evidence-reference **shapes** for the seller and all active
buyers and returns only **unadmitted** buyer obligations. It does not verify
signatures, authority, payment or legally binding purchase acceptance.

**Privacy:** the private quote includes individual purchase intentions for
host-side audit and MUST NOT be published in ActivityPub/Iroh. Public campaign
metadata needs a separate disclosure-approved aggregation adapter.

This pure portable Elixir 1.19/OTP 27 app has no dependency on the federation
transport or existing business writers. Hosts must integrate CommerceCore
price revision, InventoryCore holds, signed local ledger admission and
FulfillmentCore/Dispatch evidence separately. Group checkout must not block
cash-only direct sales, and no company can be legally formed by source code.

Run:

```sh
cd apps/group_buy_core && mix test --warnings-as-errors
mix format --check-formatted mix.exs "lib/**/*.ex" "test/**/*.exs"
```

See [current ADR](../../docs/architecture/2026-10-26-group-buy-pledge-purchase-gate.md)
and [implementation issue #137](https://github.com/larsbx/biz-kit/issues/137).
