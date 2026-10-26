# Seller-home authority for conditional group buys

Status: implementation milestone for #137 and #143. This extends the canonical
`CoopSubstrate.Log` / EventStore business ledger; it creates no second ledger.
The current binding-pledge decision supersedes the optional second-election
interpretation in the older contracted-volume preview.

## Authority and admission

1. An already-declared chapter governance key signs `GroupBuySellerAuthorizedV1`,
   pinning an exact seller actor, Ed25519 key and expiry. There is no self-appointed
   seller or bootstrap bypass. Governance genesis still has the substrate's
   existing out-of-band trust/pinning requirement.
2. Buyers independently establish their current identity key through the existing
   self-signed `MemberRegistered` / old-key-authorized `KeyRotated` registry.
   That seller signs `GroupBuyMemberAuthorizedV1` eligibility credentials for
   those exact registered buyer actors/keys, expiry and active status. A seller
   cannot replace a registered buyer key or manufacture consent with another key.
   These are marketplace access credentials, not cooperative membership. Updates use expected credential versions;
   seller authorization replacement invalidates credentials and offers under the
   previous authorization. Initial identity registration retains the substrate's first-use trust model;
   external actor ownership/KYC enrollment is not implemented.
3. The seller signs `GroupBuyOfferPostedV1`: exact integer minor-unit cash price,
   all tiers, SKU, unit, currency, capacity, deadline, revision and fixed binding
   policy. The campaign is immutable. A changed schedule requires a new campaign
   and new consent. `GroupBuyOfferClosedV1` closes new access and pledges; it does
   not erase recorded obligations or preactivation withdrawal rights.
4. The buyer signs an **unappended** `GroupBuyConsentV1` envelope. It binds chapter,
   seller, campaign, the hash of the original seller-signed offer, binding policy,
   exact pledge quantity and ceiling, opt-in expiry, command ID and expected round
   version. A withdrawal likewise identifies the pledge and current version.
5. `GroupBuys.acceptance/2` wraps that complete canonical signed consent in a
   seller-signed `GroupBuyContractAdmittedV1`. `GroupBuys.submit/2` goes through
   `Log.append`. The appender verifies both signatures and current scoped keys,
   offer and consent expiry, member eligibility, replay IDs and expected version,
   and applies `BindingRound` against its committed projection. Pending members
   are rechecked when activation occurs. Threshold activation is part of that
   one event; there is no second buyer election or separate activation race.
6. Only a durable append returns an admission receipt. Recovery re-verifies
   every group-buy signature, authority dependency, replay identity and state
   transition. Inconsistent history raises rather than reconstructing invented
   contractual volume. Existing dual hash chains/checkpoints detect history
   tampering; independent retained checkpoints remain necessary against tail
   rollback by a storage administrator.

Admission timestamps are seller-home seconds. The seller countersigns in the
current second; the appender rejects an admission from any other second. Rebuild
and re-sign the *outer* admission on `stale_admission_time`, retaining the original
buyer consent. This deliberately fails closed at expiry boundaries and prevents
backdating activation to include an expired pending pledge. This is an internal
trusted-host API; do not expose a route accepting caller-supplied gate states,
ledger servers, arbitrary append guards, signing seeds or timestamps.

Exact same-event retries return the original durable receipt and never add units.
Rewrapping an already-admitted consent is rejected. In a withdrawal/threshold race
only the command matching the serialized round version wins. Later expiry or
access withdrawal cannot erase already-bound obligations. Normal individual cash
purchasing remains independent; no existing checkout path changes. Legacy
`Contracted` seal rules and composition previews remain unchanged and pure.

## Private seller-authorized offer delivery

A member signs `GroupBuyPrivateReadV1` with the exact terms hash, request event ID,
short expiry and an X25519 recipient public key. `GroupBuys.deliver/3` accepts only
`:private`, admits that read against current seller and member credentials and
returns an encrypted packet. The original seller-signed offer remains inside.
Ephemeral X25519, HKDF-SHA256 and AES-256-GCM bind the signed request as associated
data. Recipients decrypt with `GroupBuys.Cipher.open/3`, verify the seller envelope
and compare `GroupBuys.terms_hash/1` to their signed request. Captured read requests
cannot expose plaintext or substitute an encryption key. Read nonces are durable
and cannot be replayed. A failed response needs a freshly signed read request.

All group-buy event types are `own_data`, stored in seller-scoped private streams.
No ActivityPub, public Iroh gossip or public listing adapter is registered for
these records. Existing discovery only accepts its allowlisted listing schema;
raw ledger access and notification subscription remain trusted host operations.
A network HTTP/Iroh RPC adapter, authenticated endpoint enrollment and production
key custody are future integration work; this milestone provides the callable
cryptographic delivery/admission boundary, not a deployed private marketplace.

## Independent gates remain explicit

An admitted conditional contract or binding obligation is not payment collection,
provider escrow, an inventory hold, stock readiness, delivery authority, tax
assessment or legal adjudication. Capacity here is the seller-posted bound, not
serialized physical stock across campaigns/cash/barter. Receipts explicitly say
`not_collected`, `not_reserved`, `not_authorized`. No call executes the legacy
stock/fulfillment previews. Provider payment/escrow, cross-channel stock holds,
consumer cancellation/refund rules and transport deployment remain #143 gates.
The fixed v1 policy permits free preactivation withdrawal; differing withdrawal
policies require a new supported policy version and new signed consent.

## Validation

`group_buy_authority_test.exs` exercises real Ed25519 signatures, canonical
encoding, PostgreSQL ledger admission, encrypted delivery, retries, concurrency,
expiry, immutable terms, forged credentials and restart recovery. The focused
`Group buy seller-home authority` hosted job runs those tests with the actual
EventStore and NIF. Group-buy core, business composition and consolidation checks
provide regression coverage for pricing, existing seals and the common ledger.
