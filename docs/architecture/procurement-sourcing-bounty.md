# Procurement sourcing bounties

The private coordinator console supports a fixed sourcing reward on a wanted
request. The Hanbali taxonomy describes juʿālah as a known reward for a
defined lawful result. The pilot result is independently sourcing conforming
goods that the buyer accepts and receives within the agreed time, followed by
evidenced closeout. The supplier's sale, the sourcing reward and any co-op
service charge are distinct components of the buyer's total cost.

[Hanbali taxonomy](2026-11-13-hanbali-commercial-contract-taxonomy.md)
· [H04 sources and limits](2026-11-13-hanbali-contract-sources.md#h04)
· [Procurement host](2026-11-08-procurement-mvp-host.md)

## Coordinator workflow

1. Record the buyer business, item specification, acceptable condition,
   quantity, currency and delivery deadline in the ordinary wanted request.
   Before recording any quote, record a fixed reward and maximum all-in total
   in minor units of the request currency. The private terms reference should
   document the buyer's authorization, qualifying outcome, cutoff,
   eligible sourcing role, returns, disputes and closeout conditions. Cancel
   the request before fulfillment and open a new one if terms must change.
2. Record a sourced quote with the enrolled supplier, its landed price
   including any disclosed fees, its expiry, evidence of stock and condition,
   and the enrolled sourcing business and its attribution evidence. The source
   must be distinct from the buyer and supplying business in this pilot.
   Separately, a direct merchant quote can compete within the same cap without
   a sourcing reward. An 85,000-minor-unit landed quote plus a 5,000-minor-unit
   reward fits a 90,000-minor-unit cap.
3. Record the buyer's explicit approval of one exact quote revision. Scope,
   enrollment, expiry and version are checked by the canonical Log. An accepted
   sourced revision identifies the one award and its beneficiary. The award
   becomes eligible for closeout after timely fulfillment through the existing
   operator or signed Dispatch path. The cutoff is exclusive and compares the
   signed fulfillment event time with the request deadline.
4. Record buyer closeout evidence after verifying fulfillment and resolution
   of the agreed return or dispute conditions. The delivery and closeout
   references must be distinct and cannot earn multiple rewards within the same
   cooperative. A disputed request blocks new confirmation or payment-evidence
   commands. A dispute preserves already recorded history.
5. The buyer uses its existing accounts-payable process. The coordinator can
   record one external payment evidence reference for the earned award. Evidence
   handles are private operator attestations except where the existing Dispatch
   path verifies a signed handoff. Biz-Kit does not issue payments or infer bank
   verification. The documented contract terms and their applicability require
   separate review for a live pilot.

Use the pilot's existing seven-day match and fulfillment measures to compare
bounty-backed requests with ordinary requests. Include the reward in the
buyer's realized total cost and distinguish awards from earned rewards and
external payment evidence.
