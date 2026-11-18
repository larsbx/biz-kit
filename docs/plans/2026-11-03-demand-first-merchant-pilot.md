# Plan: prove merchant demand and unit economics before international exchange complexity

Date: 2026-11-03. Status: **product decision / proposed pilot, unvalidated commercially**.
Owner: biz-kit marketplace/commerce. Execution tracking:
[issue #308](https://github.com/larsbx/biz-kit/issues/308).

## Decision

**Product promise:** "Tell us what you need. Our network of independent merchants will locate it, verify it and arrange delivery at a competitive *all-in* price."

The network is **demand-first**. Start with a *wanted-item registry*, merchant quote discovery and conventional procurement/consignment. Do **not** ask a merchant or customer to solve a barter cycle just to purchase an item. Do **not** require an international auction, QR network, consensus protocol, trade-credit system or multilateral clearing engine to produce the first successful sale.

The main problem to validate is **economic participation**, not computational match optimality. A mathematically correct match has no commercial value if there is no qualified inventory or the merchant's net contribution after acquisition, intake, inspection, storage, freight, payment, returns, claims and support is negative.

### Active, optional and deferred product surfaces

| Scope | Product action | Gate |
| --- | --- | --- |
| **P0 pilot** | Buyer wanted request with specific requirements; qualified merchant offers; buyer acceptance; supplier-led delivery; conventional external payment; costs/fees measured | Execute small geographic/category experiment before broad build |
| **P1 only after liquidity** | Verified merchant consignment intake against wanted requests; store-to-store procurement; price comparison or multiple quotes; narrow reverse-quote competition | Positive store and platform margin and signed operating agreements |
| **P2 independently gated** | Federated wants/provides projections, merchant inventory discovery, QR handoff receipts, specialized B2B international auctions | Two-node operational evidence, inventory/QR/claims safeguards, country/category legal review |
| **Deferred** | Direct person-to-person barter and unrestricted auction bidding | Not a present priority or acceptance dependency |
| **Separate research/gated capability** | Multilateral barter, financial/credit issuance, international commercial netting, crypto/bank settlement, global auction consensus | Actual recurring eligible commercial obligations, enforceable discharge, economics, regulatory approvals and safety evidence |

This supersedes the urgency assigned to [consumer P2P draft #305](https://github.com/larsbx/biz-kit/pull/305) without erasing the possibility of consumer-to-consumer barter later. The business-only agency preflight in [draft #303](https://github.com/larsbx/biz-kit/pull/303) may eventually support merchant permissions; it is **not** merchant KYB or a current runtime authorization gate. Work in [commercial audit #290](https://github.com/larsbx/biz-kit/issues/290) and [source-bound proof #298](https://github.com/larsbx/biz-kit/pull/298) stays separate and is not on this pilot's critical path.

## Pilot hypothesis and treatment

**Hypothesis H1 — demand concentration:** A few local merchant partners can source a substantial share of specific, verifiable wanted items *faster or at lower total cost* than buyers' present sourcing process.

**Hypothesis H2 — merchant incentives:** Merchant revenue from incremental qualified demand **more than covers** the merchant's additional handling, sourcing, fulfillment, claims and acquisition costs. No participating merchant is expected to subsidize other merchants' inventory without negotiated fees.

**Hypothesis H3 — platform incentives:** The marketplace's *realized* referral/coordination fee covers its own incremental support, acquisition, fraud, technology operations and returned/disputed transactions; GMV is a diagnostic, not success.

The first pilot uses **one geographically concentrated merchant cohort** and **one product category**. Choose the category only after interviews; possible candidate: spec-identifiable commercial replacement parts. Seek 5–10 merchants and ~100 *qualified* wanted requests as provisional experimental sample sizes, not observed demand. Favor products with model/part identifiers, relatively high unit value and controllable shipping/inspection risk. Do **not** claim those figures establish statistical certainty.

Pilot can be executed concierge-style with an authenticated request form, private merchant notification, conventional payment links from a contracted provider, and controlled spreadsheet/CRM records. **Do not build complex federation or automatic auctions until the pilot shows a real improvement.** Software may be added incrementally only to remove an observed operational bottleneck.

## Minimal commercial workflow

1. **Buyer wanted request:** Record buyer-controlled private request, category, part/model or measurable specifications, acceptable condition, quantity, time window, geographic delivery/pickup range and preferred all-in price. Obtain publication/merchant-contact consent; do not make buyer identifiers public.
2. **Qualify:** Human or host validates feasibility and specificity; classify duplicates, withdrawn and suspicious requests. Ineligible requests never inflate demand-matching denominator.
3. **Invite merchants:** Notify an explicitly opted-in, scoped merchant cohort. A wanted request is demand, *not* a payment mandate or legally binding order.
4. **Merchant quote:** Quote from responsible merchant with specific inventory or sourcing commitment, condition proof, availability timestamp, all-in landed price broken down by tax/freight/fees, seller-of-record identity, hold expiration and lead/handling fee schedule. Price comparison and quote competition **are not auctions**.
5. **Buyer selection:** Record explicit acceptance of a versioned quote and transaction terms; reconfirm stock/condition with the owning merchant at acceptance time. Concurrent acceptance, stale/withdrawn quote or unavailable stock must be held/refused.
6. **External checkout:** Merchant of record (or separately contracted, properly authorized provider) takes the payment through conventional channels. Biz-kit neither holds buyer funds nor claims paid status from a QR code or payer assertion.
7. **Merchant-controlled fulfillment:** Seller owns shipment or collection. If a *different* store inspects/holds/hands off goods, its fee, scope of custody, damage liability, claim evidence and payout responsibility must be agreed before accepting work.
8. **Proof and resolution:** Capture item-specific verified receipt, exceptions, returns and disputes; close order only after reconciliation. Reversals are independent actions, not rewrites of unrelated merchant books.
9. **Fee allocation:** Record realized, authorized fees and payouts *after* verified provider/payment and fulfillment evidence; no unilateral deduction or global clearing account.

**No coercive network loop:** Participating stores can quote/supply or refer without storing other stores' merchandise. A fulfillment role is an **opt-in paid service**, not a duty imposed by federation.

## Merchant contribution and liability: mandatory term sheet

Before accepting a partner, record:

| Responsibility | Default pilot position |
| --- | --- |
| Price, stock, condition and title | Supplying merchant certifies and remains the **seller of record** unless a different seller-of-record agreement is signed |
| Intaking third-party merchandise | Only if expressly contracted; inspection, photo, storage and rejection fees agreed upfront |
| Inventory custody | No transfer by default; explicit custody acceptance, serial/condition evidence and insurance/liability terms if transferred |
| Delivery and loss | Shipping party, carrier service and applicable transfer-of-risk terms identified before buyer accepts |
| Refund / buyer dispute | Seller-of-record responsible under its sales contract and consumer law; network may coordinate but must not promise automatic guarantee |
| Referral / acquisition fee | Only on realized attributable transactions under agreement; define clawbacks for refund/fraud and whether acquiring store is compensated |
| Service store / fulfillment location | Paid inspection/storage/pickup rate; no expectation of unpaid labor benefiting another store |
| Network fee | Disclosed, collected by authorized merchant/provider arrangement; platform's actual margin measured separately |
| Governing law | Relevant local business/consumer terms, product restrictions, tax and insurance; country-specific review before international use |

Every fee split should be tested against **two contribution margins**, not a single network-average commission.

For a realized transaction `t`, use integer minor units and a single currency:
`merchant_cm(t) = merchant_realized_revenue - acquisition_cost - intake - inspection - storage - packaging - fulfillment_cost - claims_and_returns - payment_fees - merchant_CAC - merchant_network_fee - allocated_incremental_support`.

`platform_cm(t) = platform_realized_fee - platform_CAC - platform_support - infrastructure_variable_cost - allocated_fraud_loss - refunds_and_fee_reversals - provider/partner_costs`.

When a *service store* or *referring merchant* differs from the supplier, compute a **third** store-level margin with its own service fee and costs. Do not offset a negative merchant with an unrelated merchant's profits and call the network sustainable.

Never aggregate minor units of different currencies; translate only under an explicit valuation date/rate when required for consolidated reporting. Neither formula measures taxes remitted, fixed corporate overhead or capital cost; disclose those separately.

### Illustrative failure check, not evidence

A $100 used item with 20% gross commission yields $20 for the merchant/network to split. If combined incremental costs are $35, **combined contribution is -$15** before even assigning margins to individual stores. This is a hypothetical caution, not a measured pilot result. Large ticket value alone does not assure margin: account for claims, fraud, freight and slow sales.

## Minimal event log for pilot measurement (data dictionary)

Every record has `pilot_id`, local immutable `event_id`, actor home, UTC timestamp and source revision. Distinguish the **owner** of a field from a remote assertion; never log unconsented PII in federated public events.

- `WantedSubmitted`: request_id, buyer pseudonymous local key, category, specification hash, geography, allowed condition, max total cost, expiry, consent revision. Buyer contact remains private.
- `WantedQualified/Rejected/Withdrawn`: request_id, reviewer, reason code, eligibility timestamp.
- `MerchantInvited/Responded/Declined`: request_id, merchant_id, invitation/response timestamp, reason.
- `OfferQuoted/Expired/Withdrawn`: merchant_id, request_id, quote_id and revision, exact item/condition, seller-of-record, price/tax/shipping/fees in currency units, stock assertion, valid-until.
- `OfferAccepted/Cancelled`: buyer authorization, exact quote version, acceptance time, revalidation outcome; no payment inferred.
- `ProviderPaymentConfirmed/Returned/Unknown`: authenticated provider reference and verification; do **not** equate network business bookkeeping with money custody.
- `FulfillmentCompleted/Failed/Returned`: merchant/carrier evidence refs, on-time status, actual delivery; QR alone is not acceptance.
- `DisputeOpened/Resolved`: reason, loss allocation, 30-day cohort status.
- `CostAttributed`: separate merchant, servicing-store and platform incremental expenses, fees, refunds and allocation basis; explicit `unknown` rather than zero for missing records.
- `RepeatMerchantObserved`: second **realized order** for the merchant, not a second quote.

Small pilot data can be entered manually and later materialized into source-owned business events. Do not claim this event dictionary is already implemented.

## Proposed scorecard / decision rules

Definitions use **eligible denominators** with observation windows, not raw app events. The thresholds are **experimental hypotheses**, not benchmarks:

| Metric | Definition | Provisional gate |
| --- | --- | --- |
| 7-day request match | qualified wants receiving ≥1 valid, item-compatible merchant quote within seven days / all wants with seven days of complete observation | ≥30% |
| First qualified offer latency | median elapsed hours from qualification to first valid offer; unmatched/waiting recorded as censored separately | <72 hours |
| Accepted offer fulfillment | orders accepted in cohort and fully delivered within promise / all accepted orders with final outcome | ≥90% |
| 30-day intervention disputes | accepted orders with human-mediated dispute in 30 days / accepted orders with full 30-day follow-up | <3% |
| 90-day merchant repeat | merchants with 2+ realized orders within 90 days of first order / first-order merchants with full 90-day follow-up | ≥40% |
| Merchant/store contribution | each merchant role's revenues minus actual incremental costs, including losses/refunds | **Positive overall and no systematically negative required role** |
| Platform contribution | realized platform fees minus incremental costs/losses/CAC | **Positive per sustainable segment and overall** |

Report request response/acceptance funnel, sample size, uncertainty/selection bias, inventory accuracy, acquisition/source mix, return rates, total landed-price competitiveness and customer satisfaction. **Do not equate 30% matching with profitable liquidity** or let revenue from one high-price transaction hide a store-loss segment. A test with insufficient volume or incomplete 90-day observation is **inconclusive**.

Run a **keep / pivot / stop** review after each cohort has appropriate follow-up. Revise hypotheses on actual transaction data, not a passing pure matching test.

## Architecture: reuse what exists and avoid accidental expansion

- `CommerceCore`: catalog/quoting/pricing conventions, not new money authority.
- `InventoryCore`: conditional stock reservations when an owner accepts; current kernel is pure, host must recheck and serialize writes.
- `FulfillmentCore` and `Dispatch`: only with independently evidenced owner/shipper permissions.
- `BizKit.Identity`: local principal lookup plus a separately implemented current merchant/KYB/agent authorization gate.
- `FederationCore` / `federation_service`: optional later read-only discovery. Public listing schema currently covers supply advertisements; **wanted request dissemination requires separate disclosure/consent and versioned schema**. Do not force consumer private wants into public ActivityPub `Page` objects.
- `CoopSubstrate`: locally authoritative business ledger where applicable. Never append foreign commands directly or mint balances from buyer desires.
- `hawala-core`: separate financial authority; **not part of pilot checkout or commercial clearing**. Provider-confirmed payments remain externally executed and subject to applicable law.

If a thin implementation is justified after interviews, use independent versioned `WantedRequestV1` and `MerchantQuoteV1` schemas with exact source/version binding, privacy-preserving projections, expiration, consent, simple deterministic ranking and explicit human review. Do **not** build full reverse auction consensus, distributed settlement, multilateral setoff or universal credits to launch this pilot.

### Example capabilities and experimental activation

`wanted_registry`: proposed first; `merchant_quotes`: proposed first; `merchant_consignment`: after service economics;
`reverse_quote_competition`: after multiple qualified offers;
`federated_inventory_discovery`: after repeat demand;
`qr_handoff`: after proven cross-store pickup need;
`direct_p2p_barter`: deferred;
`multilateral_barter`, `international_auction`, `commercial_clearing`: disabled until independently approved.

These are **policy stage names, not existing runtime feature flags**.

## Risks the pilot cannot waive

No public disclosure of consumer identity or private wanted history without consent. Check product provenance, seller identification, fraud, counterfeit/stolen goods and safety restrictions. Enforce applicable consumer protections, marketplace seller duties, returns, privacy, taxes, shipping claims and the contracts identifying seller-of-record. International trade, third-party value transmission, novel credits or cross-border regulatory classifications require *separate legal and provider review*; mere barter or routing changes do not create an exemption.

**Result needed:** actual evidence that merchant networks fulfill real wants *profitably and reliably* faster or better than buyers' alternatives. Until then, distributed infrastructure remains an option, not the value proposition.
