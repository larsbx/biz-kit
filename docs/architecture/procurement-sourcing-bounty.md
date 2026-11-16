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
   operator or signed Dispatch path. Delivery must precede the exclusive
   cutoff. Manual fulfillment admission refuses the fraction of a second
   where its rounded signature time would otherwise make a late delivery
   appear timely. Signed Dispatch uses the authenticated delivery event time.
4. Have the authorized reviewer inspect the buyer's closeout evidence and the
   agreed return and dispute conditions. Governance signs an attestation for
   the current fulfilled request version. The coordinator enters the resulting
   attestation ID to record the reward as earned based on that review. A dispute
   blocks new closeout or payment evidence records and preserves prior history.
5. The buyer uses its existing accounts-payable process. The coordinator can
   record one external payment evidence reference for the earned award using a
   separate attestation for the new request version. The console labels both
   records as attestations. Signed Dispatch verifies a handoff under its
   enrolled key. Contractual performance and bank verification require their
   own evidence.

## Signing an attestation

Use the [offline governance procedure](2026-11-08-procurement-mvp-host.md)
with the existing chapter governance key. The `ProcurementBountyEvidenceAttestedV1`
JSON file contains `type`, `chapter_id` and a `payload` with `cooperative_id`,
`request_id`, `purpose` (`closeout` or `external_payment`), `evidence_ref`,
`expected_version` and `expires_at_ms` (exclusive UTC epoch milliseconds).
Use a private record handle. The returned `event_id` is the attestation ID.

```sh
PROCUREMENT_ENABLED=false bin/procurement eval 'IO.inspect(ProcurementHost.ReleaseTasks.attest_bounty("/private/bounty-attestation.json"))'
```

The signed scope and version identify the frozen buyer, supplier, sourcing
business, terms, reward, currency, selected quote revision and delivery
reference. Payment evidence also binds the recorded closeout. A request or
enrollment version change requires fresh review and a fresh attestation. The
Log checks the current enrollment of all three businesses and serializes
confirmation and reference deduplication. Delivery, closeout and external
payment references can each be consumed once per chapter and cooperative.

For a live pilot, the reviewer needs authorized buyer assent to the private
terms, evidence of the sourcing business's attribution and independence,
conforming goods and timely delivery, and clearance of the agreed return and
dispute conditions. Establish who may verify those facts and which private
records are acceptable before signing. To attest to payment, reconcile the
external accounts-payable record to the same buyer, beneficiary, award amount
and currency. A signed attestation authenticates the reviewer’s recorded
assertion. H04 defines the entitlement by actual performance under the
agreed terms.

Use the pilot's existing seven-day match and fulfillment measures to compare
bounty-backed requests with ordinary requests. Include the reward in the
buyer's realized total cost and distinguish awards from earned rewards and
external payment evidence.
