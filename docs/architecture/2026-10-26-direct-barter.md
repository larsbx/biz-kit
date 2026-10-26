# ADR: network-mediated, participant-direct barter

Date: 2026-10-26. Status: **first pure matching/conditional-accounting preview,
not an operational or financially authoritative exchange**.
Tracking: [#131](https://github.com/larsbx/biz-kit/issues/131).

## Decision and relationship to Hawala

Biz-kit federation publishes *supplier needs as well as supplies*. The
application indexes authenticated opt-in projections, filters compatible
terms, and computes possible two-party swaps and bounded N-party cycles.
Participants independently negotiate and enter the same explicit agreement
**before delivery**. A network node may route messages and compute options,
but must never become an undisclosed principal, merchant of record, stock
holder, payment intermediary or obligor. For a three-party cycle A→B→C→A,
each supplier transfers **directly** to its own named recipient; no party
resells inventory merely to facilitate routing.

Reuse patterns from Hawala—peer identity binding, signed intents, durable
receipts, idempotency, reconciliation and explicit admission—**not** its
balances, exchange rates, credit, deposits, custody or transfer permissions.
Barter is exchange of identified goods/services on mutually consented terms,
not a Hawala monetary claim or fungible platform credit. If a transaction
introduces money, payment, transferable debt, merchant credits or regulated
custody, a separate approved financial domain and legal review are required.

## Canonical matching input (local pure v1)

- Each intent is `%{id, owner, revision, valid_until, provides, needs}`. The
  two HTTPS identifiers must have the same home origin and must have passed
  a separate authenticated publisher and disclosure check.
- `provides` and `needs` each contain an exact canonical `code`, `unit`
  and positive integer `quantity`. Different item codes or units do not
  silently match or convert. No floating point, division or FX is used.
- Expired notices are excluded; revision and expiry are included in the
  immutable, length-prefixed SHA-256 terms fingerprint. Two distinct intents
  may belong to the same business but **cannot appear together** in a route.
- For successive intents `i→j`, `i.provides` must match `j.needs` by code
  and unit and cover the latter's quantity. The leg is a direct conditional
  transfer from `i.owner` to `j.owner`. A route must close back to its
  first participant. Different legs have different quantities and assets.
- Search considers at most 16 intents, cycles of length 2–4 and at most 100
  results. This bounded deterministic first slice is neither a globally
  optimal matching engine nor a fair allocation or scarce-stock lock.
  Cycle enumeration prevents duplicate rotations but does not resolve
  competing overlapping routes. Hosts must serialize stock reservation.
- The pure kernel accepts only in-memory typed maps, **not** untrusted
  ActivityPub, Iroh messages or private direct messages. A dedicated
  versioned federation schema and transport adapters are still required.

## Consent, accounting and fulfillment protocol

1. **Discover:** advertise owner-authorized needs/supplies with provenance,
   revision and freshness, filtered by time/location, jurisdiction, quantity,
   service constraints, trading policy and counterparty eligibility. Public
   publication is not availability, authority or contract acceptance.
2. **Route:** return a fully explained set of direct `from→to` legs and
   immutable digest. Present the entire cycle, quantities and deadlines to
   *every* participant; a proposed cycle must never be silently repriced.
3. **Agree:** each party explicitly signs acceptance to the same exact digest
   and its own conditional performance, identity, jurisdiction, warranties,
   remedies and deadline. Messages use private authenticated exchange,
   replay protection, scoped approvals, and a durable inbox/outbox. A
   public ActivityPub Offer or gossip announcement cannot consent.
4. **Pre-delivery accounting:** on receipt of verified and fresh consents,
   each independently administered host admits *local* contingent
   receivable/payable-in-kind obligations, optionally inventory holds with
   explicit versions and expiry, and a durable receipt containing the common
   digest. An unadmitted preview is neither a ledger entry nor proof of
   accepted consideration. Local admission must check current grants and
   prevent double allocations. Only a contractually agreed all-party
   readiness rule can authorize proceeding.
5. **Handoff:** original supplier directly transfers to its intended recipient.
   FulfillmentCore/Dispatch or a service-specific adapter collects independent
   proof. Receiver evidence is distinguished from courier assertions.
6. **Close/recover:** reconcile each participant's separately signed history
   against digest and per-leg receipts. Missing acceptance, partition,
   withdrawal, disputed performance, short delivery or an expired hold
   transitions through explicit cancellation, compensation/dispute paths,
   not fictitious globally atomic rollback.

## Non-negotiable trust boundaries

- Existing `FederationService` discovery and gossip are read-only public
  advertisement planes, not contract execution interfaces. Keep existing
  `bizkit.marketplace.listing.v1` unchanged and design a new versioned,
  owner-consented offer/need projection. Only home-origin signed, moderation-
  approved and freshness-qualified projections enter route discovery.
- Keep CommerceCore, InventoryCore and FulfillmentCore portable. Admissions,
  evidence validation, stock holds and debt/receivable accounting are the
  responsibility of independently governed installations' existing local
  signed ledgers. Foreign data must never execute a local command.
- Never publish private counterparties' details, buyer demands not opted into
  disclosure, legal addresses, phone numbers, financial or school records.
  Advertisements cannot establish verified reputation or delivery.
- Hashes do not prove signatures. A reference in a purported consent is not
  actual authenticated consent, and unanimous evidence references do not
  prove all independent ledgers committed. No naive two-phase commit
  guarantee through lossy networks.
- Protect against stale listings, compromised keys, double allocation,
  conflicting route proposals, cycles made of controlled aliases, valuation
  manipulation, sanctions/regulatory limits, nonperformance and disputes.

## Demonstrable acceptance and next integration gates

First pure kernel acceptance tests cover two/three/four-party cycles, exact
unit/quantity checks, expirations, duplicate input, owner impersonation,
private-field rejection, bounded search, digest pinning, and absence of
automatic delivery/settlement.

Follow-on PRs must ship consented federation wire, signed agreement transport
and receipts, local event/InventoryCore adapters, two-node failure-recovery
tests and physical-delivery evidence. Existing federated marketplace
[#115](https://github.com/larsbx/biz-kit/issues/115) remains the discovery
parent; this proposal is independent of any payment authorization.
