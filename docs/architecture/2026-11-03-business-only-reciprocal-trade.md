# ADR: business-only reciprocal trade membership and cross-border fulfillment

Date: 2026-11-03. Status: **policy decision + pure nonauthoritative preflight**;
not a deployed enrollment, regulatory approval, or transaction admission gate.

Owner: biz-kit barter/commercial marketplace. Related: [business marketplace](2026-10-24-federated-marketplace.md),
[pooled broker](2026-10-26-pooled-brokerage-clearing.md),
[commercial ledger clearing](2026-11-03-ledger-first-commercial-clearing.md),
[audit #290](https://github.com/larsbx/biz-kit/issues/290), and draft
[source-binding PR #298](https://github.com/larsbx/biz-kit/pull/298).

## Product decision

The marketplace combines:

- **B: genuine multilateral B2B barter** — members exchange real specified
  goods/services under mutually agreed commercial contracts.
- **C: B2B cross-border reciprocal fulfillment** — a verified business may
  contract for a different verified business to receive specific goods/services
  from another verified supplier under documented consideration and delivery.

**Only verified businesses may be commercial members, suppliers, purchasers,
contracting counterparties or designated recipients.** People and service
principals may operate only as authorized agents of a particular business,
within an operation-scoped, revocable, expiring grant. An agent never receives
a personal trade-credit account or becomes a separate commercial member.

Accepted legal forms may include registered companies, cooperatives,
partnerships and documented registered sole proprietorships trading solely in
their commercial capacity. A personal retail/consumer account is never a
substitute for documented business status. Natural-person identification may
be needed for beneficial ownership or agent verification, but must not be
published or used to form public marketplace membership.

Business-only membership is **not** a financial-regulatory exemption.

## Boundaries and authority

- Business identity: existing biz-kit principal registry and independently
  verified legal-entity/registration evidence, with home/tenant ownership.
  A public ActivityPub actor or HTTPS identifier is NOT KYB evidence.
- Agent: authenticated current `prn_` principal, current signed local agency
  grant and specific business, operation, duration, and jurisdiction scope.
  User sessions and agent grants are not business incorporation evidence.
- Commercial authority: only the legal entity can become party to a contract,
  receive/owe consideration and authorize local inventory/receivable entries.
  A verified agent may sign only on its behalf under applicable authority.
- No remote node may mutate another node's signed books. The platform holds
  no network-wide bank balance and no separate financial writer.
- `hawala-core` retains financial custody, native money/credit books, bank
  execution and monetary authority; no alias from barter to Hawala is granted.

## Admission state machines

Business: `application -> verification_pending -> approved -> suspended/revoked`.
Approval requires actual KYB/company-registry evidence, authorized
organizational signatory, current status, ownership/control diligence
appropriate to risk, sanctions screen, allowed jurisdictions and product
categories, renewal/expiry, and an immutable audit decision. A stale or
self-asserted `approved` state is insufficient.

Agent: `requested -> entity_approved -> active -> expired/revoked`.
Agency grant binds `{home_node, tenant, business_id, principal_id, grant_id,
revision, allowed_operations, expiry}`; recheck signer, scope, version and
revocation under the authoritative local write gate. Employment, an actor URL,
a QR code, API token possession or a foreign peer assertion do not by
themselves establish agency.

Transaction:
`discovered -> quoted -> matched -> all_businesses_eligible ->
agent_scopes_current -> regulatory_classified -> all_party_contract_signed ->
local_reservations -> performance_verified -> lawful_discharge_evidenced ->
locally_posted -> reconciled`.
Suspension, dispute, returns, partial delivery, expiry and failed/unknown
cross-node states must be explicit. A matching or clearing preview does not
change legal or accounting state.

## B and C operating profiles

**B / commercial barter:** advertise actual in-stock goods/available services
and business needs; optimize exact allocations; require all legal entities'
authorized contracts and independent, locally reserved stock; confirm actual
delivery and fair-market tax valuation. No automatic value issuance.

**C / cross-border fulfillment:** allow only preidentified business recipients
and specified real goods/services under an enforceable trade contract.
The purpose, importer/exporter, invoice, agreed consideration, end use,
shipment and delivery evidence must be reviewable. A designated recipient
cannot be an arbitrary consumer/family member or an unrestricted beneficiary.
Do not use merchandise, fabricated invoices or multi-hop setoff as an
undocumented substitute for transmitting funds to someone elsewhere.

Cross-border transactions are **held** until the operator has reviewed
jurisdiction-specific money-transmission, foreign-exchange, sanctions,
export-control, customs and tax obligations. If substance amounts to a
third-party value-transfer instruction, route to properly licensed providers
or reject it. A bartering label or business-only network does not decide
legal classification.

**Permanently unavailable to this pure profile:** transferable credits,
cash/payout instructions, exchange into redeemable scrip, money custody and
unrestricted third-party value transfer. They require separate authority and
regulatory implementation; do not enable them by editing a client-side flag.

## First code slice and limitations

`BarterCore.BusinessParticipation.preflight/4` is dependency-free pure
shape/policy screening for supplied business and agent snapshots. It rejects
personal membership, unapproved business forms/statuses, missing/wrong-scoped
agents, expiry, flagged sanctions states, and unsupported financial scopes.
For commercial scopes it returns
`:host_authority_verification_required`; for cross-border fulfillment it
returns `:held_for_independent_cross_border_classification`.

Its snapshots are **caller supplied and unverified**. The state is never
`authorized` or `admitted`. Existing marketplace, brokerage and clearing
entry points are **not yet protected by this helper**. No live account
enrollment, signature verification, regulatory decision or enforcement is
provided by this increment.

## Required implementation sequence

1. Authoritative, source-backed business registry/organization binding in
   existing local biz-kit identity and signed governance, with KYB evidence,
   documented responsible humans, expiry and revocation.
2. Current agent grant schema and local signature validation; operation-scoped
   access for publish, negotiate, contract, clear and confirm fulfillment.
3. **Host-side default-deny enforcement** for every write-capable marketplace,
   private quote, brokerage, reservations, contract, clearing and fulfillment
   endpoint. Internal API and federated ingress must not bypass it. Legacy
   APIs must not silently grandfather consumer/person counterparties.
4. Independent classification of C using business-recipient destination,
   explicit commercial purpose and contracted goods/services; hold cross-
   border until approved in each relevant country. Separate sanctions,
   restricted party, goods, end-use, tax and documentation review.
5. Two independently governed live nodes with entity and agent churn,
   forged/stale/revoked grants, spoofed business identities, retries,
   concurrent commitments, partitions, shipments/returns and refusal
   of personal beneficiaries, payment proxies and replayed signed intents.
6. Preserve the source-bound consent, no-double-discharge and accounting
   admission acceptance ladder in issue #290 / PR #298; never infer legal
   discharge or financial finality from the pure barter plan.

## Verification targets

Unit tests cover preflight rejection of individual accounts, cross-entity
agency, missing operation scopes, expired/revoked business or grant,
blocked sanctions assertion, malformed evidence, and money capabilities.
These establish only the pure function's behavior; they do not certify KYB,
OFAC screening, legal agency or cross-border compliance.

Hosted exact-head tests and formatting are required. Rollout remains disabled
until independently reviewed end-to-end host admission and legal controls.

For regulatory context consult FinCEN's facts-and-circumstances money
transmission guidance, OFAC sanctions rules, BIS end-use/end-user controls and
the IRS Form 1099-B barter exchange instructions.
