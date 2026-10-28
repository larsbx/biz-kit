# Decision: member pledges cover volume; only then offer group-price purchase

> **SUPERSEDED POLICY:** The current rule is that a member pledge is a
> conditional purchase commitment that becomes **binding when the seller-home
> admits enough pledged units to meet the posted minimum**. There is no
> optional second buy click. See
> [the governing conditional-binding ADR](2026-10-26-group-buy-conditional-binding.md).
>

Date: 2026-10-26. Status: **current group-buy purchase-option semantics**.
Revises the overstrict "advance contracts unlock rates" interpretation in
[the contracted-rates ADR](2026-10-26-group-buy-contracted-member-rates.md).

## Product rule

**Pledges are fine.** Participants can indicate nonbinding purchase interest
in exact quantities through the members-only marketplace. Their valid, active,
host-verified pledges count toward the seller's **posted minimum volume**.
When those pledges collectively cover a threshold, members who pledged can
see and elect the discounted **option to purchase**. They do not have to
first sign binding purchase contracts. Before the threshold, the discounted
purchase choice is unavailable; the posted rate schedule and how many
additional units are needed may still be shown privately to members.

This separates four states:

1. **Member-only offer posted:** seller-authorized solo cash price,
   quantities, expiration and stepped discount rates. No public prices or
   individual member purchasing details.
2. **Pledge gathering:** eligible members pledge provisional quantities,
   revised or withdrawn according to marketplace policy. Pledges are not
   payments, reservations, enforceable sale commitments or guaranteed stock.
3. **Volume covered:** authenticated, currently valid pledged units satisfy
   a posted minimum, within advertised seller capacity. The corresponding
   group-priced **purchase option** becomes available to participating
   members. More pledges can unlock deeper price tiers.
4. **Buyer elects purchase:** a buyer elects the currently available option.
   The seller home independently reconfirms active pledge volume and exact
   quote revision, current seller inventory and member eligibility, then
   admits an actual buyer-authorized order/payment/stock hold. No prior
   unanimous group contract is implied by seeing an option. The seller must
   define closing/fulfillment and the consequences of withdrawals or failed
   purchase elections so discounts aren't silently guaranteed against a
   vanished threshold.

**Ordinary member cash checkout remains independently available**, including
before the group minimum is met. The volume gate applies to the **discounted
group purchase option**, not to all monetary purchases.

## Pure API behavior

- `GroupBuyCore.quote/3` calculates eligible volume from distinct,
  non-expired pledges and validates seller offer, source revision, units,
  currency, capacity and each buyer's maximum acceptable group unit price.
  It emits `purchase_option_available: true` only when an advertised tier
  minimum has been covered. It reports the unlocked rate, savings, next
  threshold, `coverage_basis: :active_member_pledges`, and the exact
  pledge-bound SHA-256 quote fingerprint.
- `GroupBuyCore.purchase_option/3` displays a **buyer-specific** option
  only for a currently active participating buyer on an unchanged, still
  covered quote. Before the minimum, after expiry, after pledge withdrawal
  or an offer/price revision, no stale choice can be used. Its output is
  a preview, **not** an authorized purchase, proof of funds or stock hold.
- `GroupBuyCore.commitment_preview/4` remains an OPTIONAL all-member
  conditional agreement preview when all alleged consent references are
  supplied. It is not required to display or elect an individual discounted
  purchase choice and verifies neither signatures nor business authority.
- `GroupBuyCore.Contracted` remains an **optional** separately stronger
  contracted closing/sealing model for sellers who need collective binding
  terms before carrying out fulfillment. It is *not* the general prerequisite
  for the discounted purchase option.
- `GroupBuyCore.MemberOffers` continues to reject any public price/rate
  projection. The host must authenticate seller publication authority,
  member eligibility and the pledges before showing private buyer-specific
  terms; URL shapes or submitted identifiers do not prove identity.

## Nonclaims / integration obligations

No live seller-home pledge registry, private federation transport, actual
payment processor, money custody, stock reservation, contractual acceptance
or legally formed brokerage company is implemented in these pure functions.
The caller must not feed unauthenticated ActivityPub or gossip claims as
verified pledges.

At a **real checkout**, independently check the threshold again under the
seller-home's authoritative snapshot, guard aggregate seller inventory from
other cash purchases/group campaigns, verify catalog cash-vs-group price
and currency minor units, bind the buyer's exact terms and fulfillment
options, authorize payment and admit local ledger events. If the campaign
no longer qualifies, **disable or re-quote** the group option; do not charge
automatically at a different rate.

The existing `BizKit.Composition.GroupBuy.preview/4` still represents an
OPTIONAL seller-sealed *contracted* batch. It must not be mistaken for the
only path to individual checkout. A separately authenticated per-buyer
purchase/election adapter is the next implementation gate.

Regression tests cover missing threshold, exact threshold, deepest tier,
solo-price fallback, buyer membership, quote expiry and revision changes,
and zero automatic payment/reservation.
