# Seller-home verification of externally signed escrow evidence

Date: 2026-10-26. Scope: **pure cryptographic gate**, not operational
custody, payment processing or ledger admission.

## Current architecture

The repository already has seller-home group-buy authority:
`CoopSubstrate.GroupBuys` records signed seller terms, member access grants,
private offers and original buyer conditional-pledge consents through the ONE
canonical business Log. The portable `GroupBuyCore.BindingRound` is derived
from admitted events, with automatically binding obligations at threshold.

`GroupBuyCore.Escrow` previously accepted a caller-supplied provider actor
tuple and evidence-reference strings in its pure reducer. This is useful for
testing, but not proof of a real financial provider's custody. In particular
an ActivityPub/Iroh relay, marketplace peer or user-supplied body could
assert a fabricated `{:custody_provider, ...}` actor and a fake hold.

## Added trust boundary

`GroupBuyCore.EscrowProof.signing_payload/1` defines an explicitly
domain-separated, length-prefixed serialization of every scoped report
attribute and every financial event field. Keys are sorted and typed.
No floats, ambiguous concatenation, dynamic atom creation, or implicit JSON
canonicalization. Reports must be exact-shape and include:

- Schema, provider ID, key ID, seller, campaign ID and offer revision.
- Unique provider event ID, report issue timestamp and signed expiry.
- The precise report type: externally confirmed *hold*, *seller
  payout/buyer surplus refund*, or *buyer refund*.
- Buyer, custody reference and exact minor-unit money amounts, plus
  pledge, provider settlement/delivery evidence or refund-resolution
  references as applicable.
- A 64-byte Ed25519 signature across the entire serialized report.

A *trusted seller-home* supplies a **separately pinned** provider grant
(provider/key/campaign/seller scope, 32-byte public key, active flag and
grant expiration). `GroupBuyCore.EscrowProof.preview/5` requires the
provider's scoped Ed25519 signature to verify, checks report issue/expiry
(600-second maximum staleness), and rejects inactive/expired/wrong-campaign
grants. It derives the reducer producer identity from the pinned grant,
not from arbitrary network claims. The provider ID plus exact campaign and
signed event reference supplies a stable idempotency key: a second valid
signature changing any facts under that same key becomes a conflict rather
than a second financial event.

Then `Escrow.apply` checks business semantics (the authenticated pledge
must exist, correct currency/amount, unique custody position, currently
binding coverage for release, already confirmed funding, delivery reference
and exact payout/refund split). Its result is explicitly tagged:

`kind: :verified_provider_event_candidate`
`authoritative: false`
`requires: :seller_home_signed_ledger_commit`

The provider grant is a **trusted configuration input**. This gate neither
authenticates the provenance of that grant nor proves provider licensing,
money actually held, authenticated delivery or lawful dispute adjudication.
The seller-home must independently obtain those guarantees through a
qualified provider contract and appropriate out-of-band checks. A valid
signature only proves which private key signed the claimed facts; never
automatically that the claims are true.

## Required canonical Log integration (still open)

The returned projection is NOT automatically admitted to
`CoopSubstrate.Log`. A production adapter must:

1. Derive the seller-home's active and campaign-limited provider credential
   from authenticated governance policy, not a caller-supplied map.
2. Verify the raw signed report at the current seller-home admission time
   while checking provider status and any externally confirmed custody.
3. Allocate provider custody/event IDs in an authoritative **cross-campaign**
   index, so the same external money/receipt cannot count for two group
   buys. The pure Escrow module only enforces uniqueness *within* a round.
4. Atomically or recoverably commit the verified evidence and the relevant
   BindingRound/capacity transition to the **same canonical signed business
   ledger**, using commit-before-execute and idempotent replay. In case of
   a split failure, never claim escrow-secured activation or release.
5. Attach provider-verified delivery proof and actual settlement/refund
   outcome. The reducer observes a **completed provider event**, and cannot
   initiate provider money movements by itself.
6. Reject expired/grant-revoked proofs, stale events, mismatched pledge
   amount/revision, replay, cross-campaign duplicate receipts, legally
   unsupported cancellation and out-of-order refunds.
7. Keep offer rates, buyer identities, private pledge and funding proofs out
   of public federation traffic.

No checkout, inventory reservation, money custody, regulated trust
approval, legally enforceable escrow, settlement API or dispatch operation
is claimed by this PR. These are the P0 acceptance gates in
[Issue #143](https://github.com/larsbx/biz-kit/issues/143).
