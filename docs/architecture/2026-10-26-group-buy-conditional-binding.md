# Decision: a group-buy pledge becomes binding when the minimum is reached

Date: 2026-10-26. Status: **controlling policy for the pure group-buy
domain**. Supersedes the earlier "nonbinding pledge, optional checkout
after threshold" interpretation in
[2026-10-26-group-buy-pledge-purchase-gate.md](2026-10-26-group-buy-pledge-purchase-gate.md)
and the "advance contracts must precede eligibility" interpretation in
[2026-10-26-group-buy-contracted-member-rates.md](2026-10-26-group-buy-contracted-member-rates.md).
Track in [issue #137](https://github.com/larsbx/biz-kit/issues/137).

## User's rule

**A member's pledge is a conditional purchase agreement.** It does not
require payment or create a currently due purchase below the minimum.
Once authenticated eligible pledged quantities reach the seller's posted
minimum, all qualifying pledges **become binding automatically** at the
published group unit price, subject to each pledger's pre-agreed ceiling.
There is no second discretionary purchase election and no collective
signature ceremony at threshold. The *original act of pledging* is the
member's conditional assent. The seller's posted offer is correspondingly
conditional on threshold and capacity, under the seller-authorized terms.

Members still have the alternative **before pledging** to purchase normally
at the posted individual cash price. After binding activation a member
owes the agreed group consideration; monetary payment remains an
available settlement method but opting out of the bargain is not merely
choosing not to click a buy button. Statutory cancellation, disputes and
applicable consumer remedies remain enforceable according to law/contract.

## States and irrevocability boundary

1. **Members-only offer posted.** Seller's cash unit price, volume tier
   rates, minimum, capacity and time limits are published privately to
   entitled members. Public ActivityPub/Iroh traffic must not expose terms
   or buyer identities.
2. **Conditional pledge.** An eligible buyer signs/authorizes an exact
   SKU, unit, quantity, seller-offer revision, deadline, payment method
   consent/ability and maximum acceptable unit rate. The pledge states
   *explicitly* that **if the group minimum is met the buyer must purchase**.
   Before activation a member may withdraw only as the published policy
   permits; expiration of an untriggered pledge removes it from the count.
3. **Threshold crossing / automatic binding.** The seller-home serializes
   admission of pledges against one authoritative current snapshot. The
   **same locally committed append** that first reaches the minimum
   activates all eligible pledges, without a second round of signatures.
   After this boundary an already-binding pledge cannot be withdrawn
   just because its original opt-in deadline expires or because the
   member does not return to the app.
4. **Settlement and fulfillment.** The seller validates inventory/capacity
   and payment arrangements, reserves goods using the authoritative
   InventoryCore writer, invokes permitted payment providers, issues
   appropriate invoices/receipts, fulfills and reconciles. A binding
   contractual obligation is not evidence money was actually collected.
   Repeated/partitioned events must not create duplicate debt or charges.

The contract must state when the minimum is met (e.g., counted seller-home
accepted units before offer deadline), the liability of an unavailable
seller, fulfillment dates, taxes/shipping, how post-binding cancellations
and refunds work, how failures/disputes are handled, and what happens
when payment collection fails. User protection laws override any term
purporting to eliminate rights.

## Deep volume discounts

The first qualifying tier activates the binding round. Additional buyers
may join an active campaign on equally explicit conditional terms, becoming
bound upon locally admitted pledge acceptance. If their additional
quantity reaches a higher posted tier, **existing buyers' unit prices
can only fall**; previously binding quantities, original evidence and
purchase obligations are not erased. No buyer is retrospectively charged
more. Exact integer pricing and a new source-bound snapshot reflect
the price reduction and credit/refund implications, which payment
integration must implement. Future changes outside the seller's posted
schedule require separate authenticated consent.

A buyer whose maximum permitted unit price is below the campaign's
first qualifying tier cannot join that round under the current
`BindingRound` contract. Their condition might be accommodated by a
separate explicitly modeled deeper-tier-only campaign, never by silently
binding them above their ceiling.

## Implemented pure model vs external legal authority

`GroupBuyCore.BindingRound` stores seller-offer terms, accepted
conditional pledges, idempotent per-command history, optimistic versioning,
preactivation withdrawal, and **automatic activation as part of the
threshold-crossing pledge admission**. It returns exact binding
per-member quantity/currency amounts and an immutable pricing snapshot.
After activation, later accepted pledges increase the bound quantity
and may reduce everyone's tier price. Expired *preactivation* pledges are
excluded; a pledge's opt-in expiry cannot annul an *activated* obligation.
Deterministic replay reconstructs the same round.

The stateless `GroupBuyCore.quote/3` / `purchase_option/3` functions
are **informational previews only**: they can predict a likely threshold
but CANNOT establish binding, since they do not authenticate signatures
or prove seller-home durable event admission. The seller-home
`BindingRound` snapshot is likewise only a pure projection of purported
host-admitted events: the host must verify that the exact corresponding
signed ledger events were committed before telling a buyer they are
contractually bound.

The existing `GroupBuyCore.Contracted` seller-sealed batch can remain
as an **optional stronger closing workflow**, not an extra buyer-consent
requirement. Nothing here creates a legally registered brokerage company,
money-transmitter authority, credit balances, cash custody, payment
authorization, a stock hold or proof of goods received.

**Critical production gate:** the host must verify authenticated seller
and buyer signatures *cover the conditional-binding rule and exact seller
terms* before admitting a pledge; checking the shape of `evidence_ref`
does not validate it. The host must also ensure seller inventory/capacity
can honor the resulting obligation atomically with, or under an
enforceable seller-backed capacity commitment at, the threshold transition.
Use local serialized signed-append commit-before-execute. Any supposed
threshold reached solely from public gossip or unverified remote references
MUST remain non-authoritative.

## Acceptance

- 4 units against minimum 5: signed conditional pledges, no present
  binding sale or payment.
- One further admitted unit: **all five immediately binding** within
  the same seller-home state/ledger transition.
- Expired pledges before minimum do not count and may be renewed.
- Attempted postthreshold withdrawal refuses; expired opt-in deadline
  does not release activated obligations.
- Additional binding units can only lower (never increase) the unit price
  according to the seller's posted tier ladder.
- No repeated event charges or binds twice, forged actor cannot bind
  another member, stale seller revisions and unsatisfied price caps refuse.
- All personal pricing and pledge data stays members-only.
- No automatic payment, escrow, stock reservation, external legal
  validation or delivery is claimed from a pure calculator.
