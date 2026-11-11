# Protected commercial discharge decision contract

Status: review prototype for [P0 #299](https://github.com/larsbx/biz-kit/issues/299).
The only positive prototype outcome is `validated_inert`. It is a historical
observation about synthetic evidence at a particular snapshot, with no executable
authority. The prototype has no ledger, posting or settlement integration.

## Upstream inputs

[PR #351](https://github.com/larsbx/biz-kit/pull/351) at
`f0cf806f5c71cf3b1fb46c19fdcaf20bb6be9773` supplies the protected profile and
the accepted `CommercialSetoffIntentReservedV2` record. Look up the actual
envelope through the verified `AdmissionGate.commercial_admission.intents`
projection and confirm ownership of every `{chapter, obligation_id}` in its
`reservations` map. Read the complete current pair and denomination set from
the same canonical prefix. Match the reservation's event ID and full hash,
profile activation event ID and full hash, party and governance declarations,
source order, and all original/latest IDs, hashes, and revisions. Re-resolve
current member keys and the governance declaration. A superseded reservation
signer or declaration fails the proposed decision gate, pending an explicitly
specified re-attestation path.

[PR #345](https://github.com/larsbx/biz-kit/pull/345), merged at
`afa8e452d25a7a1e27046263d6bc06e2b970aa75`, supplies the complementary
`CommercialSourceLineage` projection. The accepted #351 head does not contain
that merge. Original untouched rows start at revision **0** in #351 and **1**
in #345. Keep the two revision fields independently named and require both
original baselines. Require open, original-attested lineage in both projections.
Verify the original and latest signed-core digests using the canonical
`Envelope.signing_bytes/1` of the events identified by the full-record hashes.
Both views must resolve to the same replayed event identities. Reject missing,
assigned, derived, inconsistent, or closed rows and assignment out-and-back.
Do not adapt revisions arithmetically or substitute one digest kind for another.

## Scope and evidence

Support two distinct business principals, one chapter and denomination, and
2–256 reciprocal open original sources. Work in signed-64-bit minor units
with checked totals. The proposal commitment extends the reservation with an
explicit per-source release allocation and residual terms. Each amount released
is between zero and its source balance, and both directional release totals
equal the lesser directional outstanding total. An unchanged aggregate does not
permit swapping sources or redistributing release across them. Residual amounts
are computed from exact originals and the proposed allocation. The decision
does not create a residual obligation. Preserve the V2 source order.

Use a domain-separated, versioned canonical envelope core for a future adapter.
Bind the chapter, operation, parties, denomination, reservation and activation
identities and full hashes, complete source rows and signed-core digests, both
revision types, amounts released and remaining, release instrument and version,
jurisdiction/activity scope, and an authorization request ID. Bind the current
principal/key and agency grant references in their respective signed attestations.
Use the existing canonical encoding and digest rules in that adapter. The
prototype JSON commitment is for fixtures and is not compatible with ledger signing.

| Evidence | Required authenticated facts and freshness |
| --- | --- |
| Corporate agency, one for each principal | Stable legal-entity ID, jurisdiction and registry reference, stable agent identity, signing key and revision, grant ID and authenticated issuer chain, exact act and scope including chapter, parties, currency and cap, validity interval, and current grant/issuer revocation status. Require documentary evidence of delegation or corporate approval where the verifier's jurisdiction-specific rules call for it. |
| Contractual release | Authenticated governing contract/version and release instrument, exact obligation schedule and per-source allocations, governing law, conditions precedent and whether they are satisfied, affected party and third-party restrictions, and qualified legal-effect verifier's signed assessment scoped to the commitment, issuer status, rule version and validity window. The assessment must identify what additional act or event would make a release effective. |
| Trade performance, per source | Authenticated invoice, underlying order or contract, delivery or service acceptance and counterparty attestation as applicable. Bind issuer, document/version, source event, debtor/creditor, denomination and amount. Resolve current dispute, reversal, duplicate, and ownership status. A document hash or a V2 signature alone does not authenticate performance. |
| Current policy | Authenticated decision from the designated authority for the exact principals, jurisdiction, activity, currency and exposure. Bind rule/data versions, applicable sanctions or eligibility checks, cap, outcome, conditions, expiry and revocation epoch. Deny unknown, unavailable, denied, conditional-but-unmet or stale decisions. |
| Independent consent | Each principal's distinct agent signs the same canonical commitment for the discharge-authorization purpose, using the current authorized key and an independently authenticated grant. Record signed approval ID, validity interval and revocation status. Check distinct legal principals, agent identities and keys and enforce applicable common-control/conflict rules. Reservation and governance signatures do not count as either consent. |

A trusted verifier constructs typed results with authenticated issuer, credential
IDs, revocation/version proofs, and trusted time. Use half-open validity
intervals and fail closed when a required issuer or trusted clock is unavailable.
Resolve effective-dated revocations and identify whether a trusted provider can
supply an epoch fence, a bounded validity lease, or neither. A provider status
lookup followed by a ledger compare-and-append does not atomically fence
external revocation. The inert decision must report its observation cutoff.
Any future effect needs an independently reviewed solution for that race.

This contract defines engineering prerequisites. Jurisdiction-specific counsel
and qualified compliance/accounting owners must establish applicable release
formalities, company authority, regulatory classification, screening and
recognition rules before an effectful design can be approved. See the
[UNCITRAL model law and enactment status](https://uncitral.un.org/en/texts/ecommerce/modellaw/electronic_signatures)
for the distinction between a model framework and applicable law.

## State and interruption semantics

| Stage | Transition and output |
| --- | --- |
| Reserved | Replay the accepted protected V2 event and original source ownership. Existing reservations have no implicit release or expiry. |
| Evidence validation | Collect read-only evidence. Prepare against a verified ledger head and authority versions. Missing or invalid evidence returns a refusal. Interruption discards the candidate. |
| Discharge authorization decision | On a fresh matching snapshot, evaluate a proposed authorization. Only `validated_inert` or a refusal is implemented. A proposed future audit receipt would bind request and commitment IDs, reservation, evaluated head, trusted time and epochs, result, verifier version, and opaque evidence references. |
| Legal effect | Disabled. A separately approved effect path would need to revalidate current evidence, record the legally effective act and its evidence, and consume exact sources atomically in the existing ledger. A validation receipt cannot drive this step. |
| Accounting recognition | Disabled. Requires independently authorized accounting treatment, effective date, balanced posting, and idempotent recognition linked to the relevant legal-effect evidence. |
| External settlement | Disabled. Requires separate authority, instruction identity, provider finality and reconciliation where a settlement is required. |

Before a future persistent receipt write, serialize with the canonical appender,
revalidate the ledger and authority fences, and compare-and-append at the
expected version. An interrupted or losing writer must leave no receipt or
partial effect. Recovery replays committed decisions as historical observations
without rerunning them against current time or revocation state. Reserve a
chapter-qualified request ID, bind its exact committed input including evidence
identity, and return the historical receipt for an exact lost-reply retry.
Reject changed bytes under the same ID. A fresh evaluation uses a new ID and
reads current state. A historical lookup is never a fresh permission check.
The Python evaluator is stateless. Its identical-input repeatability does not
implement persistent request IDs or this retry protocol. Lean and Quint
abstract receipts by snapshot and request contents.

Keep documents, keys, personal identifiers and detailed adverse findings in a
case-scoped evidence store with access checks for both principals and verifier
roles. Use opaque case-local references in restricted receipts. Restrict
counterparty output to agreed terms and a minimal result, and suppress evidence
references and denial reasons on wider views. A shared digest of a predictable
document can leak its contents through guessing. Do not put raw evidence or
public document hashes in the business journal. Review retention, erasure and
audit access separately. The fixture output is internal.

## Reproduction

From the repository root, with Python 3, Lean and Quint on PATH:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s formal/commercial_decision -v
lean -DwarningAsError=true formal/lean/BizKitCommercialDecision.lean
quint test formal/quint/commercial_decision.qnt --backend=typescript
quint run formal/quint/commercial_decision.qnt --backend=typescript --invariant=safety --max-samples=1000 --max-steps=25 --seed=42
```

Lean checks conditional safety for arbitrary source lists under abstract
evidence, epochs and clocks. Quint independently exercises a two-source,
single-reservation model with a conflicting owner and interrupted preparation.
Its simulation is sampled. The Python fixture evaluator exercises exact source
and evidence bindings, allocation, freshness and independence. These checks
do not establish refinement of Elixir/PostgreSQL, cryptographic verification,
restart durability, multi-node receipt persistence, confidentiality
enforcement, or externally effective authority. Any integrated follow-up must
test those boundaries at its exact revision.
