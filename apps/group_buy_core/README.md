# GroupBuyCore — collective purchasing without compulsory middlemen

> **Current semantics:** Seller cash prices and group rates are members-only, and only accepted *contracts* (not pledges) unlock discounts. See [CONTRACTED_MEMBER_RATES.md](CONTRACTED_MEMBER_RATES.md).\n\n

Independent sellers can offer a group-buy campaign that attracts many
buyers across biz-kit's federated marketplace. Each buyer maintains an
**ordinary cash-payment alternative**. A seller can voluntarily incentivize
collective purchases using explicitly funded, decreasing volume price tiers.
Joining a campaign is optional and the pure kernel never collects money,
reserves stock, establishes a brokerage or accepts a purchase.

`GroupBuyCore.quote(offer, pledges, now)` computes a deterministic private
preview from the source-bound seller terms and revision-bound buyer pledges.
It excludes expired pledges, rejects oversubscription and incompatible price
caps, and shows the group tier only when genuinely unlocked. Every buyer gets
exact integer cash and group-price totals and savings. The entire candidate
is bound to an immutable digest; no cross-currency arithmetic occurs.

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

See [ADR](../../docs/architecture/2026-10-26-federated-group-buy.md)
and [implementation issue #137](https://github.com/larsbx/biz-kit/issues/137).
