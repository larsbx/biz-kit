# Hawala: shared identity and scoped authority

Date: 2026-10-28. Status: **proposed**; no Hawala event types, bindings or
authority adapter are implemented. Paired with hawala-core's
[ADR 0004](https://github.com/larsbx/hawala-core/blob/main/docs/decisions/0004-biz-kit-shared-identity-scoped-authority.md).
Both records state the same decisions D1–D6; a change to one requires the same
change to the other.

## Context

The [single-source-of-truth](2026-10-11-single-source-of-truth.md) target is
one signed ledger for biz-kit's business state, with no permanent cross-ledger
bridges. Hawala-core is a separately governed peer-to-peer financial domain.
Every change to its customer claims or dar exposure must be ordered by exactly
one named financial authority per credit lot and collateral allocation. The
[federated marketplace](2026-10-24-federated-marketplace.md) and
[group-buy escrow](2026-10-26-group-buy-external-escrow.md) records already
keep Hawala balances out of biz-kit.

This record states what biz-kit may share with Hawala, and the single
condition under which its ledger may order Hawala settlement.

## Decisions

**D1. Identity is shared by key, not by registry.** A Hawala identity is an
Ed25519 public key. `BizKit.Identity` may bind it to a `prn_` principal
through an explicit binding, never through email or a label, in the same way
the resolver binds `{issuer, subject}`. The binding is biz-kit's own fact and
confers no Hawala authority. Revoking a grant, session, device or binding ends
the key's biz-kit authority only. It does not revoke the Hawala identity or
invalidate its historical signatures, which Hawala never revokes.

**D2. Attestations are portable evidence.** Hawala credentials, co-signed
receipts, dual-signed obligations, and payout and settlement acknowledgments
may be carried verbatim as `{:bytes, _}` payload fields. A signed checkpoint
over them proves retention and position in this log only. It does not prove
their validity (re-verify the Hawala signature), cash movement, finality or
any authority, whether in Hawala or in biz-kit.

**D3. One key may sign in both systems only under disjoint signing inputs.**
`Envelope.signed_core_term/1` is a map, so its canonical encoding starts with
a CBOR map head (`0xA0..=0xBB`). Every Hawala identity-core signing input
starts with `hawala-identity-core/v1\0`, whose first byte `0x68` is a
text-string head. The input sets are disjoint. That holds only while a key
bound under D1 signs nothing in biz-kit except envelope cores (or other
inputs proven disjoint). Device statements, capability documents and other
ad hoc signing inputs must use separate keys, or carry a proof of their own.
A test pins this on both sides.

**D4. This ledger is never the network-wide Hawala ledger.** Gossip,
federation, marketplace, barter and group-buy surfaces hold no Hawala
balances, credits, deposits or exchange permissions. This narrows the
single-source-of-truth target. Hawala's financial state is outside biz-kit's
business state, not a competing fact inside it.

**D5. One instance may be a named Hawala authority for an explicit scope.**
An instance *A* may implement Hawala's `admit(operation, authority_envelope)`
contract for a declared scope *S* (named operators' credit lots, collateral
and dar exposure), under Hawala's single-operator custody profile. Hawala
defines the contract; biz-kit implements it. In that case *S*'s events are
native to *A*'s log, so no bridge exists. Enabling *S* requires all of the
following:

1. **Single commit.** One serialized append batch consumes the QR nonce and
   event ID, reserves custody, applies balanced postings, checks dar exposure
   and rechecks policy, grants, quote and expiry. Otherwise the result is
   `HOLD`. The existing append gate has this shape; the Hawala checks are new.
2. **Accounting.** The `hawala-ledger` invariants hold as a pure projection
   fold: balanced per currency, nonnegative natural balances, and idempotency
   by event ID and posting hash. `CapitalAccounts` (credited/redeemed per
   member) does not satisfy them and is not reused.
3. **Integer range.** Amounts fit `CoopEventCanonicalV1`'s i64 range, or are
   decimal strings at the schema layer. Hawala's u64 balances are not
   truncated silently.
4. **Governance fence.** No governance or administrator event, including
   `mix coop.revoke`, changes issued customer claims or collateral in *S*.
   Revocation reaches only grants for future operations.
5. **Refinement.** Hawala's Lean/Quint lifecycle traces (`formal/traces/`)
   replay against the fold and append gate as conformance tests.
6. **Custody, law and review.** Asset reconciliation, licensing, AML/KYC and
   independent security/legal review are in place. Neither codebase provides
   them.

**D6. Clearing between authorities stays a Hawala protocol.** Dars ordered by
different authorities settle through Hawala's bilateral coordination
contract, not through a shared or bridged ledger. That keeps "no permanent
cross-ledger bridges" true.

## Consequences

- Under D5, accounts in *S* commit only while connected to *A*. A partition
  yields `HOLD`.
- *A*'s operator becomes the regulated custodian or operator for *S*.
  Deploying *A* for *S* is a legal decision as much as a technical one.
- D1–D3 are cheap, carry no authority, and can proceed independently of D5.

## Next steps

1. Verify Hawala's published identity-core test vectors in Elixir (D1, D2).
2. Add the D3 disjointness test in `coop_substrate`.
3. Only then consider a scoped authority adapter (D5).
