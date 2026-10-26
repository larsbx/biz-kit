# Members-only group offers and optional contracted closing

> **SUPERSEDED POLICY:** The current rule is that a member pledge is a
> conditional purchase commitment that becomes **binding when the seller-home
> admits enough pledged units to meet the posted minimum**. There is no
> optional second buy click. See
> [the governing conditional-binding ADR](2026-10-26-group-buy-conditional-binding.md).
>

> **Updated semantics:** Contracts are **not** required before displaying a
> group purchase option. Authenticated member pledges covering the seller's
> minimum unlock the opportunity to purchase; see
> [current decision](../../docs/architecture/2026-10-26-group-buy-pledge-purchase-gate.md).
> The separately sealed contracted aggregate below is an **optional
> stronger close-out workflow**, not the default volume eligibility gate.

**Private posted rates:** Normal cash prices and all group tier prices are
seller-owned **members-only offer** terms. The public federation/discovery
plane MUST NOT expose them. A trusted host must authenticate seller grants,
recipient membership and disclosure scope before calling
`GroupBuyCore.MemberOffers.private_offer/3` and deliver its result through
a private authenticated channel.

**Optional contracted closing:** A follower or click is not a contracted
unit; a valid member pledge is sufficient for the preceding purchase-option
volume gate. `GroupBuyCore.quote/3` retains a clearly *indicative* soft-demand
forecast and can never issue a binding group commitment.

`GroupBuyCore.Contracted` models the authoritative seller-home
accepted-command projection, with host-authenticated purchase contracts,
idempotent versioned admission, permitted pre-seal withdrawal and seller
seal. The seller's posted lower rate becomes eligible only when enough
unexpired **contracted** units are counted and every buyer's price ceiling
covers the rate. The seller can seal the immutable quote; no funds or stock
are reserved by these pure functions.

`BizKit.Composition.GroupBuy.preview/4` combines a currently sealed
contract quote with a published CommerceCore catalog SKU/currency,
InventoryCore's proposed versioned stock reservation, and separate
FulfillmentCore opaque handoffs for each buyer. The candidate is
**non-executable**. Host admission still requires verified signed
seller/member authority, catalog cash-price conversion, local ledger
append, payment provider, logistics and recovery. No customer PII is
federated. Ordinary cash checkout remains an option for eligible members.

Run `cd apps/group_buy_core && mix test --warnings-as-errors`.
See [ADR](../../docs/architecture/2026-10-26-group-buy-contracted-member-rates.md).
