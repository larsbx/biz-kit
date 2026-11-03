# Commercial bilateral setoff: source-bound verification contract V1

Status: **inert verification-contract increment**, 2026-11-03. Depends on
commercial clearing V1.1 PR #291 and the open audit in issue #290.

## Existing authority and the source-binding gap

The existing `NettingExecuted` event registers two roles, `party_a` and
`party_b`, and cryptographically signs the canonical envelope containing
`party_a`, `party_b`, denomination, `a_to_b`, `b_to_a`, `setoff` and
optional residual fields. Its append gate recomputes current aggregate
`Finance.compute/3` totals and checks current member keys.

It **does not** sign the individual source obligation IDs, their revisions,
their event hashes, source evidence, agency authorization, the applicable
contractual setoff basis, a legal-effect determination or a governing-law
decision. The membership fold records an obligation's current debtor,
creditor, amount, denomination and open status, **not** its current source
event revision or verified trade provenance. A subsequent set of receivables
with identical aggregate amounts can therefore be indistinguishable to a
legacy aggregate-signed `NettingExecuted` event.

Do not treat any legacy event's two signatures as signatures on the contract
defined here. No `NettingExecuted` envelope/payload has been altered, and
no compatibility-breaking reinterpretation of existing signatures is allowed.

## Versioned source-bound commitment

`CoopSubstrate.CommercialSetoffProof.prepare/8` constructs an **unsigned**
version-1 proof candidate. It signs **no** event and writes **no** ledger.
The commitment is:

```
bytes = "biz-kit/commercial-setoff/source-bound/v1\\0"
        || CoopEventCanonicalV1.encode(body)
commitment = SHA256(bytes)
```

The body contains:

- Domain and integer version `1`, chapter, globally unique proposed
  `intent_id`, sorted pair IDs, denomination, computed per-direction totals
  and exact setoff amount.
- A deterministically ID-sorted **complete set** of open pair obligations
  for that chapter and denomination. Every entry carries obligation ID,
  authoritative positive revision, source-event digest (32 bytes), debtor,
  creditor, integer minor units and denomination. Duplicate IDs and
  cross-currency or unilateral sets are rejected.
- Both participant IDs, their then-current registered member key IDs and
  Ed25519 public keys, and an independently governed agency-grant digest.
- Governing-jurisdiction identifier and distinct digests for legal basis,
  legally effective discharge evidence, and jurisdiction/activity policy
  classification. These are **references to be checked**, never automatic
  proofs merely because a hash is populated.

All principals sign the **same** domain-separated canonical bytes, using two
distinct currently registered keys. `verify/6` accepts separately supplied
signature records and checks their actor/key match and cryptographic validity.
The verifier recomputes the source set and amounts against the local canonical
Membership gate and compares the entire newly constructed commitment to the
previously signed one, including supplied latest source revisions and active
agency grants. A changed source, even with unchanged totals, invalidates the
candidate.

The verifier's explicit result is
`inert_cryptographic_checks_only` with `admission: :not_authorized`,
`legally_effective_discharge: :not_verified` and
`financial_settlement: :none`. Neither the proof nor its signatures
automatically become a local business event, release, or Hawala posting.

## Required independent owner evidence BEFORE authoritative admission

Each source-owning authority must provide an independently authenticated,
latest-version obligation or invoice record, its source signer, source event
revision/hash and reliable evidence of actual underlying performance,
assignment and ownership. No caller-supplied revision map counts as verified
unless that evidence was checked against an owner-controlled, current history.

Each participant must be independently authenticated, expressly consent to
**this exact commitment**, and have an unexpired, unrevoked agency/role grant
to agree on discharge for this organization, claim type and amount. A
registered member key alone does **not** establish corporate agency.
Signatures must be checked against current grant state at serialized
admission, after any key rotation or authority revocation. Delegation,
segregation of duties and bilateral independence require policy evaluation,
not merely two Ed25519 signatures.

Legal-effect evidence must identify relevant contracts and any valid
setoff/novation/release terms, mutuality and ownership of receivables,
governing law, effective date, dispute/insolvency/tax restrictions, and
applicable jurisdiction- and activity-specific licensing/sanctions decisions.
The authorized reviewer/validator, decision version, effective scope,
expiry and signed result must be retained and revalidated on admission.
A digest of an unsigned legal opinion, or a Boolean `allowed`, is
insufficient.

These three independently governed evidence ports **are not implemented**
by this increment. The current proof checks only consistency with supplied
snapshots and public-key signatures; it does not authenticate an external
source-history service, corporate-grant issuer or legal authority.

## Safe admission and replay architecture — still blocked

Future **versioned** business-only `CommercialSetoffAdmittedV2` (name
provisional) must include the exact source commitment (or complete canonical
source terms), individual approval records, source-owner attestations,
legal-effect evidence IDs and validator decision fingerprints **in the
signed schema**. Register an explicit strict type/schema and check it in the
**existing** `CoopSubstrate.Log` serialized append authority, rather than
introducing a new writer.

The append gate must lock affected obligations in canonical order, confirm
their current revisions and zero active discharge/reservation, revalidate
both actor keys and scope-specific grants, and atomically reserve/use
`{chapter_id, intent_id}` and every source ID/version, append the
authenticated business journal and persist a replay fence. Reject duplicate
intent, replay, overlap, post-rotation stale signatures and missing legal
admission evidence. Rebuild reservation/discharge state from durable history
on restart. Test racing independent admissions and crash/restart recovery.
A `MapSet` supplied to the inert V1 verifier is **only a unit-test/model
fixture** and cannot enforce this invariant at scale.

Existing aggregate-signed `NettingExecuted` must not be promoted to this
higher assurance level. A migration/deprecation and gate hardening plan is
required before production commercial discharge: otherwise the legacy route
could bypass a new protected pathway. A two-node scenario needs its own
protocol, independently governed durable receipts and HELD on unknown or
partial outcomes. Never infer cross-node ACID or legal effect from a local
append.

## Accounting and financial separation

An accepted *business accounting* event may update per-actor payable/
receivable projections; it is not by itself an enforceable legal release.
Actual lawful commercial discharge needs separate effective-evidence
acceptance. Hawala financial accounts, custody, native TigerBeetle postings,
provider authority and cross-network financial finality remain owned by
`larsbx/hawala-core`. Neither this proof contract nor any local event
can instruct a bank, transfer cryptocurrency or create financial credits.

## Reproducible negative controls

`apps/coop_substrate/test/commercial_setoff_proof_test.exs` exercises exact
ID binding, deterministic order, substituted same-total obligations, stale
source revision/hash, cross-currency refusal, absent/mismatched signatures,
active-grant revocation/replacement, live member-key rotation, snapshot
replay guards, and a real legacy `NettingExecuted` discharge invalidating
an old source snapshot. Fixtures for the external source, grant and legal
evidence are explicitly synthetic. These tests do **not** prove legal
validity, source-history authenticity, durable replay atomicity or jurisdictional
compliance.

Acceptance is **blocked** on the exact-head hosted workflow passing, plus
the external evidence validators and serialized admission guards described
above. Do not merge a protected production execution route until those
additional controls exist and receive independent review.

Related: #290 (open P0 audit), #291 (V1.1 implementation),
`docs/architecture/2026-11-03-ledger-first-commercial-clearing.md`.

## Signed local source-history extraction (increment 2)

`CoopSubstrate.CommercialSetoffSources.snapshot/4` now offers a read-only
snapshot for a **single local canonical business log**. It enumerates open
mutual obligations in the current serialized Membership gate, reads each
source-owned `ObligationRecorded` stream, independently checks the stored
Ed25519 envelope signatures, extracts its full-record hash and stream
revision, and rechecks that the Log head did not advance while collecting
those records. It returns the same gate and exact source terms for
`CommercialSetoffProof.prepare/8` without inventing source hashes.

This increment rejects any source with more than one event (including
assignment out and back), because the V1 current-obligation projection
does not retain the provenance chain of changed debtors. It also refuses
one-way, absent, or excessive source sets; substituted same-value
obligations receive different source IDs and hashes. Negative controls
exercise real signed Log streams, changed source sets, and restart replay.

**Limitations:** checking signature validity on an accepted business event
does not establish invoice authenticity, trade performance, agency authority
or legally effective release. Per-stream reads and a stable-head observation
are not a serialized reservation, financial commit, full log-chain audit,
or an independently administered foreign node verification. Source revision
coverage excludes assigned obligations until their complete signed lineage
can be validated. The helper is inert and cannot authorize or submit a
`NettingExecuted` event; the legacy aggregate-signed bypass is unchanged.
