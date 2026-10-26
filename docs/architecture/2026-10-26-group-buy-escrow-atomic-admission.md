# Durable escrow evidence: authenticated grants and atomic funded contracts

Date: 2026-10-26. Extends merged #147 and #148; tracks #143. This is evidence
admission in the existing seller-home Log/EventStore, not operational escrow.

## Provider credential provenance

`GroupBuyEscrowProviderAuthorizedV1` requires the chapter's already admitted
**governance** key. It commits a stable provider ID, Ed25519 key, key ID,
active state, expiry, monotonic expected version, provenance reference and
SHA-256 evidence commitment. Sellers cannot authorize their own providers.
The governance operator must independently authenticate the provider identity,
key ownership and provenance document before signing. A hash/signature records
who authorized the credential; it cannot establish the truth of that document,
provider licensing, legal qualification or actual funds.

`GroupBuyEscrowProviderPinnedV2` is seller signed and references that exact,
current, active governance authorization event. Its expiry cannot exceed the
authority expiry. Provider reports must use the matching campaign grant and
signature. Governance renewal, rotation or deactivation invalidates old pins
for **new admissions**, even when the public key is unchanged; the seller must
explicitly repin. Stale pin revisions refuse. Historical V1 pins and evidence
continue to replay at their original admission time; seller-only V1 pins can
no longer authorize new evidence. Existing V1 histories must obtain a governance
authorization and V2 pin before adding further provider reports.

The authority namespace is a trusted governance responsibility: provider IDs
must stay stable across key changes and must not alias one custody provider
under multiple names. Existing `(provider_id, event_ref)` and
`(provider_id, custody_ref)` nullifiers cover all campaigns in this canonical
Log, not independent installations. Provider-global allocation protection is
still required externally.

## Atomic threshold admission and recoverable observations

`GroupBuyFundedContractAdmittedV1` contains the original signed buyer consent,
the original canonical provider-report bytes and expected escrow version.
`GroupBuys.funded_acceptance/4` constructs the unsigned seller envelope. The
seller signs it and submits it through `GroupBuys.submit/2` / `Log.append/2`.

One pure transition authenticates the contract using the existing consent
reducer, verifies and applies the provider proof, checks global nullifiers and
requires complete unexpired **held** evidence for every bound obligation.
The existing EventStore transaction then commits ONE signed event. An invalid
signature, underfunded position, stale grant/version, missing prior buyer's
funding or any transaction failure commits neither the proposed contract nor
its provider event/custody nullifiers. There is no second ledger or post-commit
threshold activation callback.

Existing independent contract admissions retain the cash-independent binding
policy. They explicitly report `payment: :not_collected`; binding alone does
not assert funding. Conditional pledges and separate provider observations can
be admitted before the final threshold. If processing is interrupted between
those observations, the Log reconstructs both projections and coverage remains
incomplete. The atomic funded admission refuses activation until all earlier
pledges also have live held evidence. No old contract is silently relabeled as
protected. Existing `Escrow.coverage/3` and stock readiness remain recomputed
read gates, never custody guarantees or payment authority.

## Retries and restart

An identical signed seller event returns its original receipt. A provider
callback wrapped in a fresh signed seller envelope also returns the original
commit when provider/event identity, chapter, seller, campaign, original proof
bytes and signer match. Funded-contract retries additionally require identical
buyer consent bytes. An altered signed receipt under the same provider event
ID is a conflict. A different campaign cannot reuse a custody allocation.

A retry can acknowledge a past commit after expiry or authority rotation. That
acknowledgement does not revalidate present custody or authorize execution.
Exact full-batch retries return original assignments; a mixed replay/new batch
refuses instead of partially applying. Reuse the original signed event for
lost-ack recovery; if a new event is needed, sign in the current admission second.

On restart the Log audits its signed chains, folds the ledger and repairs
missing derived stream links. Provider-event and custody nullifiers, authority
provenance and both funding/contract projections recover from the same records.
The regression suite exercises an actual PostgreSQL insert failure and models
the post-commit/pre-link/pre-fold/pre-ack crash boundary with a test-only direct
EventStore write of the correctly assigned canonical event.

## Remaining production gates

- Select and qualify a real provider for the actual jurisdictions, assets,
  custody terms, fees, consumer rights and cancellation rules; authenticate
  governance provenance and provider credentials outside these test fixtures.
- Reconcile real protected balances, allocation uniqueness across installations,
  lost callbacks, provider partitions, hold expiry, chargebacks and disputes.
- Independently attest inventory and serialize cash/barter/group reservations
  together. The existing group-only stock projection is not general oversell
  protection, and seller-asserted stock is not warehouse verification.
- Verify delivery/Dispatch and legally permitted cancellation evidence; connect
  provider-controlled release/refund receipts through durable execution/outbox
  recovery. This change neither sends payments nor authorizes settlement.
- Validate two independent homes with a real/sandbox provider and an authorized
  warehouse/delivery adapter. No such acceptance or money movement is claimed.

All these records remain private seller-home data. They are not public
federation listings, and no provider credentials or member prices are published.
