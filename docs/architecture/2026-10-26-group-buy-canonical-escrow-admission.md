# Escrow attestations enter the one seller-home canonical business Log

Date: 2026-10-26. Status: **signed provider-evidence admission and
cross-campaign reference guard**, not live escrow custody.

## Why this boundary matters

The existing `CoopSubstrate.GroupBuys` already admits seller-authorized
members-only offers and original buyer-signed conditional-binding pledges
under the one canonical Log. `GroupBuyCore.EscrowProof` already verifies
a separate external provider's Ed25519 signed reports, but previously
produced only `authoritative: false` previews. A provider-signature
check outside the authoritative Log can be raced, replayed or discarded.

This change makes a **seller-countersigned external evidence event** a
first-class canonical Log event, never a second operational ledger.

## Registered private event contracts

`GroupBuyEscrowProviderPinnedV1`: seller-home signs a scoped provider key
pin (seller ID, campaign, provider ID, key ID, 32-byte Ed25519 public key,
active flag, expiry, expected version). The append gate validates the
current seller-home credential and optimistic replacement revision.
A revoked/inactive pin cannot admit later evidence. The provider pin is
a trusted local seller decision, not independent verification of bank
licensing, a custody contract or real protected funds; the seller-host
operator must verify those separately.

`GroupBuyEscrowEvidenceAdmittedV1`: seller-home signs the exact original
externally signed provider report as canonical CBOR bytes, plus seller,
campaign and expected escrow projection version. At append, the gate:

1. Authenticates the active seller's registry key and current campaign.
2. Requires the envelope's admission timestamp to fall in the
   **seller-home's current second**, not an old provider claim.
3. Strictly decodes canonical CBOR with exact keysets and typed events,
   verifying all provider cryptographic evidence using
   `GroupBuyCore.EscrowProof` and the **previously pinned** provider key,
   scoped to the original offer revision and campaign.
4. Runs the existing `GroupBuyCore.Escrow` pure transition against the
   pledge round admitted to this same canonical ledger. Claims cannot be
   accepted from public gossip, with unknown buyers, wrong money amounts,
   repeated signatures, wrong custody scopes or insufficient provider
   report freshness.
5. Enforces **global-within-this-Log** nullifiers for provider event
   `(provider_id,event_ref)` and custody `(provider_id,custody_ref)`,
   stopping one signed provider receipt or funding allocation from being
   reused by another campaign in the same seller-home chapter or in
   another chapter of that canonical Log.
6. Advances `escrow_states`, `escrow_grants`, `escrow_provider_events`
   and `escrow_custody_claims` **only** as the signed Log event appends.
   These projections are deterministically reconstructed and checked on
   restart from the canonical ledger's full signature/hash chain.

The appender's existing preflight and serialized verification ensure a
rejected event changes neither ledger head nor any projection. Durable
event admission is not a provider payment instruction, proof that money
was truly escrowed, nor a new bank account.

## Atomicity across pledge activation and provider evidence

The canonical Log permits an **ordered atomic batch**: valid original
buyer pledge admission followed by verified seller-countersigned provider
evidence. The second event sees the first event's projected admitted
pledge and must pass signature, amount and custody checks before the
entire batch is durable.

A conditional pledge may also be admitted before its provider funding
report. In this state it is binding upon threshold, but must NOT be
advertised as **escrow-secured** or proceed to delivery/payment release:
`Escrow.coverage` blocks unless every binding buyer has current verified
protected funds. Hosts must distinguish contractual status from funding
readiness. Avoid claiming a temporary in-memory preview is a committed
financing fact.

## Remaining P0 / no false assurance

- The seller signed provider key pin is not a reliable *independent*
  provider qualification check; a production provider adapter must
  validate permitted custodians, contracts, evidence source and key
  lifecycle, and respond to key compromise/rotation.
- Custody refs/event refs are globally unique only **inside this
  canonical seller-home Log**. A real provider must enforce the same
  allocation across independently governed seller installations and
  across every application, or make all holds unique by provider-global
  binding identifiers. Cross-home double spend remains open.
- No provider API, money movement, bank hold, settlement command,
  reserve/stock admission, payment processor, consumer cancellation
  adjudication or delivery proof authenticity is implemented.
  Signed custody assertions may still be false or revoked at the provider.
- Price-tier reductions imply cash surpluses due back to buyers; actual
  credit/refund and delivery release require provider-backed integration.
- Event schemas are private `:own_data`; no public ActivityPub or
  Iroh relay should broadcast seller prices, buyer pledges or provider
  financial evidence. The Log's visibility controls and hosting security
  still require deployment-level review.

Track remaining work in
[issue #143](https://github.com/larsbx/biz-kit/issues/143).
