# ADR: consumer participation at the edge — direct P2P barter and business-mediated consignment

Date: 2026-11-03. Status: **approved product direction, pure inert preview only**.
No consumer onboarding, live settlement, inventory reservation or public endpoint is enabled.

This ADR *supplements*, rather than removes, the [B2B-only commercial domain](2026-11-03-business-only-reciprocal-trade.md)
being developed in [PR #303](https://github.com/larsbx/biz-kit/pull/303).
It is deliberately implemented as a **separate consumer marketplace capability**.
The core member-governed business clearing federation remains B2B-only.
Related acceptance: [business admission issue #302](https://github.com/larsbx/biz-kit/issues/302),
[commercial clearing audit #290](https://github.com/larsbx/biz-kit/issues/290),
[barter issue #131](https://github.com/larsbx/biz-kit/issues/131).

## Decision

Admit eligible **adult individuals** to a separate consumer marketplace in two modes:

1. **Direct P2P barter:** individual A directly contracts with individual B
   to trade particular goods/services. Both are identified and authorized
   separately at their home nodes; neither obtains a business principal or
   authority to post business clearing entries.
2. **Business-mediated consignment:** an individual supplies an identified item
   or service under a documented consignment/brokerage authorization to a
   verified merchant business. Its scope-limited agent coordinates a deal with
   an individual **or business** customer; the merchant cannot claim the
   consumer's title, grant its own financial authority or debit consumer
   accounts by presenting an agency/grant reference.

Domestic, specified in-kind exchanges are the first supported **planning**
profile. Future cash purchases need the appropriate external checkout
provider, merchant-of-record and consumer-sales treatment, which are
separate from this initial in-kind preview. No portable trade unit or token
is created by this design.

Cross-border consumer barter or consignment is **held** until independently
reviewed for all relevant legal, trade, sanctions, consumer and
money-transmission concerns. A physical good's delivery to a third party is
not *automatically* a remittance, but a disguised value-transfer service can
be regulated based on substance. No claim of a blanket barter exemption.

## Identity, privacy and access boundary

Individual credentials must be verified and current, including age status,
risk/anti-fraud criteria and geographic eligibility. Versioned, revocable
participation and privacy/consent decisions live only on the participant's
authoritative host. Personal identifiers are NOT exposed in public ActivityPub
or shared commercial market snapshots. Public advertisements use opaque,
minimal, consented listing references; private profile, legal name, date of
birth, address, tax ID, verification record and contact information are
restricted to authorized workflows. Implement deletion/retention rules and
applicable identity/marketplace legal obligations.

Business intermediaries need independent legal-entity verification
(KYB and registration evidence), valid business-specific agent grants and
an **actual, transaction-specific consumer consignment agreement**.
An agent's possession of an API token, QR code or `prn_` identifier is not
evidence of authority. The consignment agreement must spell out title,
custody, commission, pricing, liability, returns and disputes.

Existing `BarterCore` source optimization remains a preview, not a live
consumer execution writer. Existing `BizKit.Identity` resolves local principal
identity, not consumer sale eligibility. `CoopSubstrate` remains authoritative
for its own signed business operations, but must not blindly enroll a person
as a company. `hawala-core` alone owns any separately licensed financial
capability, monetary value, custody and cross-authority settlement.

## Required separate state machines

Consumer account:
`requested -> verification_pending -> eligible -> suspended/revoked`.

Direct barter:
`opt_in_listing -> proposal -> bilateral_verified_consent ->
stock/title_check -> conditional_reservation -> two_party_delivery ->
evidence_check -> reconciled`.
Dispute, cancellation, partial delivery, fraud review and compensation are
explicit alternate paths. No ledger entry automatically discharges a
consumer's contract.

Consignment:
`owner_intent -> merchant_verified -> agency_verified ->
owner_supplying_title_evidence -> consignment_terms_signed ->
stock_custody_or_non_custody_confirmed -> listing ->
qualified_buyer_agreement -> delivery -> returns_window/reconciliation`.
A broker's control of actual inventory creates liability and relevant
consumer-law requirements that cannot be delegated away merely by software.

Cross-border:
`proposed -> regulatory_hold -> counsel/provider_classification ->
jurisdiction_and_goods_checks -> separately_authorized_path`.
The preview deliberately has no automatic transition from HOLD to executable.

## First pure implementation

`BarterCore.ConsumerExchange.preview/2` validates the *shape* of an exact
snapshot for `:direct_p2p` or `:business_consignment`:

- Two distinct, host-asserted current adult individual principals for direct
  P2P; broker must be `nil`.
- Individual seller, individual **or business** buyer and a separately
  eligible business intermediary for consignment.
- Business intermediary's agent with explicit single
  `:consignment_intermediation` scope and positive grant revision.
- Seller-consent reference, consent revision, pinned terms hash, current
  broker/grant/consent expiry and exact in-kind goods/needs references.
- Explicit rejection of unknown beneficiary/payout fields, transferable
  credit and arbitrary money representations.
- A deterministic source-preview digest changing on consent/grant/offer
  revisions. This digest is not a signature or validated legal consent.
- Domestic results always require independent host admission. Cross-border
  results always remain on regulatory HOLD.

All input evidence is **unverified host assertion**; no legal-age,
beneficial-owner, identity, corporate agency, ownership, stock, invoice,
sanctions, payment or tax verification is performed. The pure function
returns no legal consent or execution authority and is **not wired into**
any publishing, account, private deal, shipment, marketplace or clearing
write path.

## Required acceptance before consumer launch

1. Separate consumer onboarding/identity eligibility registry and account
   suspension/revocation; prohibit any transition from person to B2B clearing
   membership without verified legal-business onboarding.
2. Narrow signed permission contracts for consumer listing/offer/acceptance,
   distinct from company/member approval and financial authority.
3. Enforce default-deny on **all** consumer public/private marketplace APIs
   and federation ingress, including revisions, internal calls, offline queues,
   QR links and past cached listings. Recheck current eligibility at write time.
4. Signed seller authorization for consignment; verify merchant agent and
   entity authority; verify claimed inventory title, authenticity, condition,
   prohibited goods, pickup/returns and custody policy.
5. Consumer safeguards: clear terms and fees, buyer protection, refunds,
   chargebacks where applicable, complaint handling, age policies, product
   safety, recall screening, privacy/data security, fraudulent listings and
   merchant disclosures.
6. Tax/accounting classification and reporting (including IRS barter FMV,
   applicable Form 1099-B and state sales/use tax); evaluate applicability of
   the INFORM Consumers Act to qualifying online marketplace activities.
7. Classify *each cross-border product/action* separately, including export,
   end-use, customs, sanctions, remittance/other value transmission and
   foreign consumer law. Use separately approved payment partners if needed.
8. Two independently governed nodes: identity/agent churn; revocation between
   quote and commit; duplicate and conflicting goods; simultaneous accept;
   tampered/forged consent; delivery refusal/returns; partition/timeouts;
   P2P cannot issue business obligation; merchant cannot bypass consumer
   authorization; no unintended credit creation or financial writer.
9. Relevant regulatory and security reviews, source-pinned CI and formal
   conformance evidence. No production claim from these pure tests.

## Legal reference points for implementation review

- IRS Topic 420: https://www.irs.gov/taxtopics/tc420
- 2026 IRS Form 1099-B: https://www.irs.gov/instructions/i1099b
- FTC INFORM Consumers Act: https://www.ftc.gov/business-guidance/resources/INFORMAct
- CFPB remittance transfer overview: https://www.consumerfinance.gov/ask-cfpb/what-is-a-remittance-transfer-and-what-are-my-rights-en-1161/
- FinCEN money-transmitter definition (facts and circumstances):
  https://www.ecfr.gov/current/title-31/subtitle-B/chapter-X/part-1010/subpart-A/section-1010.100
