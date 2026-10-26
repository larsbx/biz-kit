# Group-buy members-only rates and contracted-volume price unlocks

Date: 2026-10-26. Status: **pure trusted-host domain models + seller-home
stock/fulfillment preview; not a deployed federation host or payment service**.

Supersedes the confusing "pledge volume unlocks prices" wording in
[2026-10-26-federated-group-buy.md](2026-10-26-federated-group-buy.md).
Tracks [issue #137](https://github.com/larsbx/biz-kit/issues/137).

## Product and authority decision

**Posted prices and rates belong to members-only offers.** Neither the
normal cash unit price nor any volume discount schedule may leak into public
ActivityPub pages, public iroh gossip, relays or unscoped discovery indexes.
Sellers may advertise an opportunity privately to authenticated, eligible
members after explicit seller disclosure approval and member entitlement
verification. Membership is managed by the seller-home host, not established
by supplying an actor URL or a boolean to a public endpoint.

The member-facing offer always contains (1) cash checkout price, (2) seller-
funded volume tier rates, (3) minimum *contracted* quantities, (4) expiry,
(5) offer revision, and (6) resource/currency and capacity. Buyers can
select ordinary purchase instead of group membership. A published tier is a
binding pricing **schedule only if the seller has separately authorized it**;
the group rate does not become eligible until the requisite quantity of
accepted buyer contracts has been reached.

A click, subscription, watch, soft pledge, unverified interest expression or
mere presence in a gossip projection **never counts** as a contracted unit.
An unverified reference to a signed receipt is not proof of a signed or
admitted contract. The platform must distinguish *indicative* demand from
contracts actually accepted through seller-home authorization and durable
local admission.

## Pure portable protocol

- `GroupBuyCore.MemberOffers.private_offer/3` constructs a private
  members-only price/rate projection **only from trusted host-controlled
  authorization context**. `public_projection/1` refuses entirely.
  Private member recipient IDs must not be serialized into public messages.
  This adapter alone does not verify membership or send messages.
- The original `GroupBuyCore.quote/3` is now explicitly an *indicative
  pledge preview*: its forecasted tier, if any, has
  `price_authority: :indicative_only_not_contractual` and
  `contracted_quantity: 0`. Pledge-only evidence cannot produce a
  commitment preview or unlock an actual group buy.
- `GroupBuyCore.Contracted.new/2` accepts a seller-owned private campaign.
  `apply/4` models trusted, serial, owner-authorized `:contract`,
  pre-seal `:withdraw` and seller `:seal` commands with optimistic
  revision checks, durable business-command idempotency and replay.
  **The host must authenticate each member's legal consent and signature,
  seller approval, applicable withdrawal rights, and ledger admission
  before feeding a command to this pure model.** This is not a network API.
- Only accepted `:contract` event projections count to
  `contracted_quantity`. Active contracts must pin seller offer ID and
  revision, quantity, maximum permitted discounted unit price, deadline,
  member identity and independently verifiable contract evidence reference.
  Contract expiration excludes units. Duplicate buyer participation, stale
  versions, impersonation, invalid source revisions and capacity overfill
  refuse. No arbitrary four-party limit.
- The best eligible seller-posted tier is selected once the minimum
  **contracted** quantity is reached. Every participating member's
  admitted price ceiling must cover that rate, otherwise the quote fails
  closed until contracts are revised or deeper volume is committed.
- A quote contains exact monetary cash/discounted amounts and savings,
  the accepted contract IDs, source-bound terms fingerprint, price/offer
  expiry, quantity needed for the next tier and explicit
  `not_reserved`/`not_authorized_or_collected` statuses.
- The seller-home `:seal` command can lock a qualifying immutable quote
  fingerprint to prevent membership changes without a fresh round. The
  seller's claimed seal reference is **not** proof of legal execution,
  stock reservation, buyer payment or escrow. Any material change requires
  explicit compensation/abandon/re-quote and fresh authorized events.

## Inventory, catalog and fulfillment composition

`BizKit.Composition.GroupBuy.preview/4` (pure composition) requires a
current *sealed* contracted quote, matching seller, SKU, catalog product and
currency, stock merchant/item/unit, quantity, explicit host-supplied
unique opaque buyer request/order references and an inventory-hold expiry
no later than quote expiry. It uses the existing `InventoryCore.apply/3`
on a **temporary immutable preview state** to validate a proposed seller-
owned versioned aggregate stock reservation, and `FulfillmentCore.new/4`
to propose one opaque handoff per buyer, without recipient PII.

The preview does not mutate the seller's stock or business ledger, authorize
payment, reserve funds, create dispatch tasks, or establish that a seller
actually signed the offer/terms. The independently authenticated, locally
admitted stock reservation remains an explicit seller-home obligation.
If the host later admits this hold, InventoryCore's existing on-hand less
held invariant prevents a competing ordinary cash sale from consuming the
same stock. Admission still must occur under one serialized trusted writer;
a preview cannot prevent concurrent overselling.

CommerceCore Catalog.quote is consulted for current product, SKU, tenant,
currency and catalog version. The group-buy's *integer minor-unit cash
price* is not automatically treated as the same type as CommerceCore's
Money values: the returned `catalog_price_compatibility:
:requires_host_revalidation_of_seller_cash_price` is an explicit **open
gate**. A production adapter must implement a verified, currency-aware,
exact conversion/reconciliation and reject price drift before checkout.

## Regulated and federated boundaries

No mandatory central reseller. A temporary participant-governed buying
company, broker or consortium would need its own separately verified lawful
formation/agency authority and member contracts; membership in a discount
campaign does not establish a corporation. Payment providers, taxes,
shipping terms, refunds, cancellations and partial fulfillment remain
separately authorized commerce obligations.

Cash checkout must remain available to eligible members without meeting a
group threshold. A buyer's cancellation after the seller seal requires
legal-policy-driven compensation/collective reauthorization; no unilateral
ledger rollback across federation nodes.

Federation can privately relay a seller-authorized member-specific offer, but
remote activities must never become local grants or durable business writes.
Private offer prices, buyer identities, signed references, order details and
financial records never belong in public listing-v1 metadata or gossip.

## Next acceptance gates

1. Authenticated membership and seller-signed private offer delivery,
   durable seller-home contract admission with membership provenance.
2. Exact CommerceCore Money/minor-unit conversion and checkout price
   drift rejection; implement actual local ledger transaction/outbox.
3. InventoryCore serialized stock reservation and expiry with concurrent
   ordinary cash sale tests and cross-campaign oversell defenses.
4. Member payment authorization and billing/tax/shipping/fulfillment
   validation; effective withdrawal, cancellation and refund policy.
5. Two independently governed federation nodes: partition, replay,
   membership revocation, stale contract, revision bump, deadline expiry
   and failed/partial delivery recovery, with explicit uncertainty.
