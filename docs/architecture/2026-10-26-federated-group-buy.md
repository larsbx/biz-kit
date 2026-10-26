# Federated group buying — seller-priced demand aggregation

Date: 2026-10-26. Status: **pure initial preview contract**, not executable
group checkout, inventory reservation, bank escrow or registered buying entity.
Tracking: [biz-kit issue #137](https://github.com/larsbx/biz-kit/issues/137).

## Decision

Group purchasing is an additional participant-facing opportunity in the
**federated biz-kit marketplace**, not a mandatory intermediary. A seller
publishes a home-origin campaign for a known SKU and exact unit. Individually
governed buyers may opt in to aggregate their quantities before a deadline.
The seller proposes a volume-price ladder. Once enough active demand exists,
everyone in that campaign may be offered the currently unlocked unit rate.

**All products still have ordinary cash prices.** A user who doesn't join a
group, who chooses cash, or whose group fails its deadline must be able to
buy using an independently authorized ordinary commerce checkout. The group
price is a **seller-funded, conditional volume incentive**, not an issuance of
unbacked platform credits or a substitute for personal payment authorization.

This applies to wholesale parts, freight capacity, materials, food orders,
supplier procurement, community goods, co-op needs and business services
where exact comparable units and commercial terms can be specified. Joining
a group does not make another member an undisclosed reseller or impose a
platform-owned brokerage company. A seller or members may *optionally*
create a temporary lawful purchasing/brokerage entity via separate member
contracts and legal formation checks. Software cannot incorporate it merely
by computing a plan or gathering clickthroughs.

## Pure contract v1

`GroupBuyCore.quote/3` requires:

- Exact-shape seller offer `{id, seller, sku, unit, currency, revision,
  expires_at, capacity, solo_unit_minor, tiers}`; seller and campaign URI
  must share an HTTPS origin. A publisher must separately prove ownership
  and consent to advertise.
- Each tier has strictly increasing positive integer minimum cumulative
  quantity and strictly decreasing integer unit price below the individual
  cash price. Quantities, currency minor units and all aggregates are
  checked for bounded exact-integer overflow; there is **no FX**.
- Buyer pledges `{id, buyer, offer_id, offer_revision, quantity,
  max_group_unit_minor, expires_at}`; each buyer has one exact pledge
  candidate for this campaign, with source revision and a future deadline.
  Authentication, withdrawal rights and privacy are host responsibilities.
- Expired pledges do **not** count towards thresholds. Duplicate buyer IDs
  and pledge IDs, origin substitution, excess demand over offered capacity,
  invalid price caps, seller/offer revision mismatch and malformed private
  fields fail closed.
- A quote shows ordinary cash amounts **and**, only when a tier is unlocked,
  the proposed discounted unit/extended amounts, precise savings, next
  discount threshold and aggregate total. Under the minimum the group price
  is **not yet available** and no discounted amount is displayed as due.
- The public result is an internal/private quote object containing the
  source pledges for audit/reconstruction. **Never federate this structure**:
  individual buyers, evidence refs and purchasing intent are private.
  A separate deliberately scoped public projection might reveal the tier,
  expiry and opt-in aggregate quantity, with k-anonymity or minimum-group
  safeguards where appropriate.
- The quote's domain-separated, length-prefixed SHA-256 fingerprint pins
  exact seller terms, active buyer pledges, the currently unlocked tier
  and related expiry. Any re-price, change in member quantity, cancellation,
  expiry or seller revision must trigger a new quote.
- `commitment_preview/4` requires one claimed exact-hash reference from
  the seller and every currently participating buyer. It only returns
  `:requires_independent_local_business_admission`, **unadmitted**
  per-buyer purchase amounts, and explicit flags that no inventory has been
  reserved and no payment authorized. Evidence-ref shape is NOT signature
  validation or legal contract formation.

## Host obligations and settlement paths

The next integration must use independently governed local ledgers and
existing CommerceCore catalog/price rules, InventoryCore reservations and
FulfillmentCore/Dispatch proof. Every seller stock hold must prevent
simultaneous direct checkout, pooled barter and multiple campaigns from
claiming the same inventory. Do not assume federated ACID; use durable
authenticated retries, idempotency and reconciliation with explicit
timeout/abort/cancellation/compensation transitions.

Seller confirmation and all buyer signatures must bind the same exact
SKU, quantity, tier, currency, taxes, shipping, delivery windows, returns,
refund and shortfall remedies. A campaign reaching threshold is not
fulfillment, guaranteed availability, irrevocable price, escrow or payment.
Each member should approve whether the sale is all-or-nothing or supports
partial fill, how pickup/shipping works and when money is collected. A buyer
may opt out and use ordinary seller payment, which requires revised group
eligibility and fresh consent where it impacts other members.

Payment options include direct individual checkout to the original seller,
or a **separately authorized** pooled purchase/escrow with explicit custody
and payment-provider/legal acceptance. Network barter offsets and temporary
member-governed brokerage may eventually be additional funded consideration,
but are never silently legal tender or balances in federation or Hawala.

## Acceptance and next steps

The pure kernel's tests cover threshold boundaries, tier incentives, 100
distinct buyers, seller/buyer consent shape, exact arithmetic, deterministic
recomputation, bounded supply, stale and duplicate pledges, currency,
price-cap refusal, no forced transaction and the ordinary cash alternative.

Following milestones:

1. Seller-origin opt-in federation schema and safe aggregate projections
   with freshness, moderation, withdrawal and source attribution.
2. Signed authenticated buyer opt-in, changes and withdrawals; no remote
   publication grants local writes.
3. Authorized local stock holds, coordinated threshold closure, deadlines
   and repeatable independent-node failure tests.
4. Normal cash checkout and optional group checkout, provider-backed
   authorization, individual receipts/refunds and delivery proof.
5. Multi-supplier group negotiation, geographical grouping, consolidated
   freight and collective purchasing optimization, with verifiable
   pricing, fairness and funding instead of arbitrary broker-imposed fees.
