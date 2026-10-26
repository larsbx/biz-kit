# Group-buy escrow: external custody, binding threshold and delivery-conditional release

Date: 2026-10-26. Status: **pure provider-evidence / reconciliation
contract only**, not a payment provider, escrow company or operational
custodial service. Complements the governing
[binding-pledge ADR](2026-10-26-group-buy-conditional-binding.md).

## Required outcome

A member's pledge is a **conditional, potentially binding order**. The
seller's signed members-only tier schedule, member quantity, maximum unit
price, cancellation rights and minimum are established before the pledge.
The threshold-crossing accepted event automatically binds members; there is
no second "buy" election. **Escrow protects both parties without changing
that contractual rule.**

Money is held **by an independently qualified and authorized custody/payment
provider**, not by biz-kit, a federation relay, a temporary brokerage shell
or Hawala-core's balance ledger. Neither a payment-intent authorization nor
an unverifiable external receipt is proof of escrow. The seller-home must
verify funds were actually protected, are earmarked for the exact pledge,
have not been simultaneously allocated elsewhere, and remain available
through contract closing. Provider custody terms and permissions require
jurisdiction-specific legal review and participant disclosure.

## Intended workflow

1. **Private offer + conditional pledge.** Members see seller-published
   individual cash price, minimum group quantity, member-only rate ladder,
   expiration and settlement/release/refund rules. A member authenticates
   and signs exact quantity and ceiling **including conditional binding**.
2. **Protected funding.** The member arranges funds with the contracted
   external escrow provider. The provider attests to protected funds
   earmarked to that member, campaign, pledge ID, currency and amount.
   Initially the protection is computed at the **first qualifying tier**
   (the maximum price at which this model can bind); that covers any
   deeper/lower later tier. Taxes, shipping and separate charges require
   independent quoting/funding and must not silently fit into this figure.
3. **Seller-home admission.** The host independently verifies the buyer's
   signature and the provider's current funding attestation, and durably
   appends both to its **own signed business ledger**. The pure
   BindingRound and Escrow projections are derived only from committed,
   authorized events. A public federation event or unverified reference
   cannot activate an obligation or represent secured funds. The host must
   use a serialized commit-before-execute boundary for the crossing event
   and funding record; two pure models are NOT an atomic transaction.
4. **Conditional period.** If eligible units stay below minimum, no
   purchase is currently due. The verified custodian protects the funds
   under the agreed terms. A permitted prethreshold withdrawal requires
   seller-home and custodian reconciliation; never leave protected funds
   orphaned after removing a pledge.
5. **Automatic binding.** The seller-home accepts the pledge that crosses
   the minimum; every eligible pledge becomes binding without another
   election. `Escrow.coverage/3` refuses to attest to an **escrow-backed**
   activation until all bound members have separately verified protected
   funds of the right amount, pledged asset and currency. No unprotected
   group may be called secured or proceed to delivery release.
6. **Price decreases.** New members can join the bound round and trigger
   a lower posted tier. Existing members' due amounts can only fall.
   After delivery, the custodian's reported split sends the current exact
   due to the seller and refunds unused protected funds to the buyer. Do
   not capture an older higher amount or assume a refund occurred because
   it was calculated.
7. **Delivery, release or refund.** The provider must independently verify
   authorized delivery/performance evidence and release instructions before
   releasing the seller's share. The pure model accepts a **verified
   observation** of an externally completed seller payout and any buyer
   surplus refund; it issues no payment order. When the campaign deadline
   passes without threshold activation, the provider confirms a full
   refund. A binding purchase can instead be refunded through separately
   authorized lawful cancellation, settlement or dispute resolution.
8. **Disputes.** A buyer or seller may open a dispute that freezes ordinary
   releases in the local evidence state. Actual freezing, adjudication and
   lawful reversal must happen at the custodian subject to its rules.
   External evidence of a valid resolution is mandatory to record a
   postbinding refund. Enforce applicable statutory cancellation rights:
   contract labels cannot override them.

## Implemented mathematical/event interfaces

`GroupBuyCore.Escrow.new(offer, now)` creates a portable exact-unit
projection. `apply(state, binding_round, verified_actor, command, now)`
accepts *host-admitted, externally verified* `:hold_confirmed`,
`:delivery_release_confirmed`, `:refund_confirmed` and
`:dispute_open` events with stable command IDs and optimistic revisions.

For each member, the evidence projection binds provider, uniquely allocated
custody reference, pledge reference, declared currency, amount, duration and
attestation evidence. It rejects missing/duplicated funding, impossible
amounts, forged provider-class claims and mismatched campaign scopes,
refunding twice, paying seller twice or reporting delivery while disputed.

`coverage/3` requires **all** currently binding pledges to be funded by
live individually identified protected positions. A host cannot claim
escrow coverage from a BindingRound snapshot alone. The provider evidence
must be checked off-chain by the host before accepting a reducer command.
`settlement_preview/4` calculates exact due vs refundable discount
surplus using the **current** binding tier. A calculation is not actual
provider settlement.

Funding evidence is initially limited to exact integer minor-unit purchase
subtotals in one currency; zero FX, credit creation, float rounding or
silently counted tax/freight. The current escrow schema is a pure domain
preview and not a provider-neutral signed network protocol.

## Essential open integration gates

- **Regulatory and provider integration:** choose a provider permitted to
  escrow these funds in each operational jurisdiction, with separate
  qualified agreement, holding account, custody proofs, release authority,
  dispute arbitration, payout, refund and expiry/renewal hooks. Do not
  create a platform-controlled wallet or call mere card preauthorization
  escrow.
- **Authentication and binding:** verify seller/member signatures and
  seller-home signed ledger admission; provably bind provider attestation to
  campaign ID, pledge and intended beneficiary. Explicitly verify external
  availability at activation, especially if provider funds expire.
- **Stock/capacity:** seller-home InventoryCore must serialize reserved
  goods for bound units and prevent overlap with direct sales, other
  campaigns, and barter. Escrow alone does not guarantee supplier delivery.
- **Tax/fees, partial orders and recovery:** calculate all terms with
  CommerceCore and valid provider rules; respect chargebacks, dispute
  windows and partial performance. Do not simulate escrow accounting as
  legally effective money movement.
- **Cross-node acceptance:** independently administered seller and buyer
  nodes, delayed/duplicate provider callbacks, stale ledger events, locked
  funds without binding, failed minimum, lowered price, partial deliveries,
  buyer rights, claims with repeated custody references, double release,
  expiration and disconnected storage.

The repo's earlier **temporary brokerage** can coordinate logistics and
contract negotiation; it is not automatically a licensed escrow provider.
Hawala remains its own separately governed financial/trust domain.
