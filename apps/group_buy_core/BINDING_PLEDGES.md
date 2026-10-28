# Binding conditional group-buy pledges

**The pledge is binding IF the seller's minimum volume is reached.**

Before minimum: individual member pledges are conditional, not currently
due purchases. When an authenticated seller-home local event first brings
the total admitted pledges to the minimum, all qualifying pledges become
**binding purchase obligations automatically**, without another buy click
or separate all-party signatures. Members who do not want a conditional
commitment should use normal cash checkout instead of pledging.

`GroupBuyCore.BindingRound.new(offer, now)` creates a pure round from
seller-priced members-only terms. `apply(round, actor, command, now)`
models a host-admitted conditional `:pledge` or authorized pretrigger
`:withdraw`. Crossing the minimum and turning every admitted pledge into
a binding obligation occurs **in one pure transition**. Stable command
IDs and expected versions ensure replay and idempotency.

`snapshot(round, now)` reports conditional volume below minimum and
bound member quantities/prices above it. Later new members can pledge
while the campaign is open; they become bound immediately, and greater
volume can reduce the unit price for all. The old pledge expiry does not
undo a triggered contract. No arbitrary participant cap applies.

The seller-home **must** verify each member's legally effective conditional
signature, seller offer, membership and right to withdraw; durably append
the accepted event; and establish stock/payment readiness before
representing the pure state as a binding transaction. The pure model
cannot perform legal validation. Actual payments, reservations and
deliveries remain external.

Older `quote/3` and `purchase_option/3` APIs provide informational
rate/threshold previews, **not a later discretionary right to opt out**.
Member-only prices and rates must never be published on public federation
feeds. See the [governing ADR](../../docs/architecture/2026-10-26-group-buy-conditional-binding.md).
