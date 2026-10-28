# Signed external escrow evidence gate

`GroupBuyCore.EscrowProof` protects the pure
`GroupBuyCore.Escrow` candidate from accepting arbitrary **unsigned**
provider receipts. It verifies a report's **Ed25519 signature** with a
**separately seller-home-pinned** active provider key scoped to one campaign
and seller. Provider ID, grant, offer revision, exact buyer and custody terms,
minor-unit amounts, event ID, freshness and expiry are included in canonical
domain-separated signatures.

The cryptographically verified result is **still only a candidate**:
`authoritative: false` and
`requires: :seller_home_signed_ledger_commit`.
The seller-home must verify real provider custody and external legal
eligibility, then durably append the accepted event to
`CoopSubstrate.Log` before any effect can be claimed. Never accept a
caller-provided grant or proof-ref string as equivalent authority.

```elixir
{:ok, prepared} =
  GroupBuyCore.EscrowProof.preview(
    escrow_projection,
    admitted_binding_round,
    external_provider_signed_report,
    trusted_seller_home_provider_grant,
    seller_home_now
  )

# Not yet an admitted event:
false = prepared.authoritative
# The host must commit, replay and reconcile the new signed event.
```

Only external **hold confirmation**, **release confirmation** and
**refund confirmation** reports are accepted from providers. Buyer disputes,
buyer pledge admission and seller approval remain separately authorized.
Round-local duplicate custody refs and provider event receipts refuse,
but cross-campaign duplication must be prevented in the seller-home's
global durable provider receipt ledger.

This is not a sandbox payment processor, not regulated escrow and not
verification that the provider actually has funds. See
[the architecture decision](../../docs/architecture/2026-10-26-escrow-provider-signed-evidence.md).
