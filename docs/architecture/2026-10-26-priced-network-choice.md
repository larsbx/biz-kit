# ADR: every asset is priced; cash remains available; voluntary network-first incentives

Date: 2026-10-26. Status: **pure priced-option and conditional netting
preview**, not payment execution or authorized brokerage settlement.
Follow-on to [#131](https://github.com/larsbx/biz-kit/issues/131),
[PR #132](https://github.com/larsbx/biz-kit/pull/132) and
[PR #134](https://github.com/larsbx/biz-kit/pull/134).

## Product decision

**Barter is an opportunity, not a restriction on commerce.**

Every supplier resource has an explicit monetary unit price, even if the
supplier would prefer a barter trade. Every buyer and seller is offered a
cash-payment path. The federation also identifies possible *in-network*
supply/need opportunities and visibly offers network participation with
verifiable economic incentives, without hiding or blocking the cash path.

The UI should display both options side-by-side:

- **Pay money:** the seller's explicit list price, currency, exact quantity,
  taxes/shipping quoted separately by domain providers, normal settlement
  choice, subject to merchant acceptance and payment-provider authority.
- **Exchange through network:** a proposed in-kind trade, or (if all members
  expressly agree) an offsetting account of priced conditional obligations
  and cash top-ups. The seller can deliberately sponsor this choice with a
  specified lower network price. The application displays the source and
  magnitude of that *seller-funded* discount, not imaginary "free money".

Network opportunities may be *ranked first* when they meet a user's
expressed constraints, but must not be deceptively cheaper due to undisclosed
fees, unfavorable time/risk assumptions, withheld delivery options or
unfunded rewards. A participant always has the right to decline and pay
the displayed monetary price, negotiate different terms, or not transact.
A cash election must not silently force other members to fulfill a pooled
exchange under now-invalid assumptions: re-quote and obtain the needed
counterparty approvals before changing any signed agreement.

## Implemented pure contract

`BarterCore.PricedExchange.quote/4` takes an *already verified*
`PooledClearing` snapshot and an exact set of seller-authored supply prices:

- One price for **every available supply line** identified by seller,
  resource code and exact unit, including lines not selected for the
  current allocation. A host must authenticate source owner and explicit
  publication consent; URI shape alone is not authority.
- The offer pins source member revision, future expiration, an ISO-like
  three-uppercase-letter currency identifier, integer minor units per
  quantity unit, and an optional **seller-funded network discount** per
  unit. A discount cannot exceed the cash price or produce negative totals.
- Each selected delivery includes a cash price, discounted network price,
  incentive size, immutable quote source revision and expiry, and both
  selectable options. **Neither is elected automatically.**
- Exact integer multiplication and bounded per-party sums reject oversized
  prices. No floating point, silent unit conversion, implicit FX, invented
  market valuations, external price feeds or unpriced supply.
- The same signed-snapshot plan and price-quote inputs always produce the
  same, domain-separated, length-prefixed SHA-256 `quote_hash`.
  Changing quantities, seller revision, discount, expiry, currency or
  original clearing plan invalidates the old agreement basis.
- A per-member/per-currency **conditional preview** shows cash payable and
  receivable *for direct payments* alongside discounted network
  payable/receivable and a separate conditional net cash position.
  Netting is zero-sum **within each currency** for the quoted transfers;
  it is not cash custody, payment authorization or financial settlement.
- The only implemented reward is the *seller's own posted price reduction*.
  The seller's expected network receivable falls by exactly the recipient's
  incentive. No platform balances, interest, emission of credits, sponsor
  debts or unbacked promises are introduced.

The optimization remains **per-resource maximum integer flow**, not
maximum economic surplus. Prices do not yet influence which supplier is
selected by the pooled matcher, and the quoted plan is not guaranteed
to be the welfare-optimal or lowest-price feasible arrangement. A later
workstream should add signed willingness-to-pay/ask, transport cost, time,
risk, economic utility, value-based routing, budget-constrained incentives
and exact integer solver certificates where possible. **Never** equate
nominal prices with guaranteed market value or truth of a party's bid.

## Authority and financial controls

The exchange may propose a temporary participant-governed brokerage, but
the pure quote does not form the entity, sign a membership contract, assume
merchant-of-record duties, obtain a money-transmitter license, reserve funds,
or create a legal obligation. A company may become a broker or clearing
party only through a separately approved charter and applicable legal
requirements. Financial settlement can use a member's existing processor
or an explicitly authorized payment interface. Neither ActivityPub gossip
nor Hawala-core's balances/custody/permissions become payment authority
inside federation_core.

Before execution the host must verify (1) seller ownership/stock and
publication consent, (2) validity/terms of buyer cash election or every
participating member's revised in-network agreement, (3) actual approved
discount capacity/terms and any domain taxes/shipping fees, (4) individually
authorized inventory holds and conditional ledger entries, and
(5) all required funds/settlement readiness or separate direct-payment
receipts. An unmatched supplier's listed cash price must also be available
for normal independent commerce; no multi-party cycle should be a
prerequisite to buying it.

The platform can add further **funded** rebates, lower service fees,
routing priority and loyalty benefits after separate anti-fraud, source
budget, user-consent, tax and financial review. No reward should imply
that the platform is minting redeemable money without backing.

## Acceptance and follow-on

Tests must cover both displayed payment alternatives for every selected
transfer, priced but unmatched supply, positive/zero incentives, no
discount > cash, exact currencies and zero-sum conditional netting within
one currency, malformed/stale/forged price records, immutable revisions,
bounded integer overflow and no silent execution.

The existing `PooledClearing` / `PooledBrokerage` public schemas remain
unchanged. This is an additive contract and must not bypass
`CommerceCore`, `InventoryCore`, `FulfillmentCore` or each installation's
signed event admission. A deployment pilot will need actual seller-side
price-publication adapters, cash checkout, user-specific preference/consent,
quote binding in the brokerage agreement, and end-to-end fee/rebate evidence.
