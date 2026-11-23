# Cross-currency business authority and non-prohibition evidence

This proposal covers review of bilateral cross-currency setoff between two independent business principals.

## Scope and trust

[PR #413](https://github.com/larsbx/biz-kit/pull/413) reconstructs two reciprocal original obligations from the canonical signed business Log. Its inputs to this port are the original full-record SHA-256 hashes and the registered member keys. The new key epoch is the local Log position of the last admitted member registration, ordinary key rotation or recovery rotation. The admission fold reconstructs it on replay. Rotating away and back changes this epoch even when the key ID and public key match the originals. This position is local to the observed Log history.

The existing `CommercialSetoffProof` checks inert source-bound consent with supplied agency evidence. The test-only cross-currency provenance fixture uses synthetic steward grants. `ProcurementContractEvidence` illustrates a configured evidence-owner boundary. `CommercialAdmission` implements an inert same-currency reservation profile at the existing serialized append gate. Each remains a separate entry point. This change adds no ingestion, live provider, event, posting, financial instruction or reservation.

The trusted host chooses the operator reference and evidence provider. A caller supplies the chapter and two expected original source IDs and hashes. The review first re-reads them from the Log. Both authority grants must bind the resulting exact scope, which includes the review activity, operator, chapter, source IDs and full-record hashes. The source events already commit to the original parties, amounts and denominations. Review scope grants cover those sources only. A particular rate, reduction and contractual assent require a subsequent signed intent.

| Evidence | Required bindings and checks |
| --- | --- |
| Principal | The provider authenticates the mapping from the local member ID to a canonically identified business registration, including formation jurisdiction, registry and registration number. Two registrations must be distinct. |
| Agent | The provider authenticates present status, identity and signing key ID, Ed25519 public key and epoch. The parties must have distinct agents and agent key material. |
| Scoped grant | The authenticated issuer, grant ID and revision identify the record. It binds the exact scope, principal, agent, agent key and current local member key and epoch. Unknown status, revocation, expiry, future validity and binding mismatches fail closed. |
| Jurisdictions | The provider authenticates the governing law of each exact source and the operator and activity jurisdictions for the exact subject. Formation jurisdictions are included from both registrations. Coverage has an evidence reference and a validity window. |
| Regulatory assessment | Each assessment identifies the complete subject, its own jurisdiction, the applicable coverage reference, authenticated issuer, assessment reference, decision and validity window. Complete favorable coverage produces `:non_prohibited`. A matched, current prohibition yields `:prohibited`. Missing, stale, mismatched or unavailable evidence otherwise yields `:undetermined`. |

The callbacks are read-only and return a normalized, authenticated view. The authority provider must check corporate appointments, issuer mandates, agent and grant revocation, issuer trust, key status and conflicts using independently maintained records. The returned grant interval is the intersection of the validity and freshness windows for all of those records, including principal and agent evidence. The regulatory provider independently resolves which jurisdictions apply, each reviewer's authority, the signed assessment and its scope. Each window includes freshness limits, and conflicting findings are handled at the evidence owner. The implementation has no configured real-world trust roots. The synthetic adapter produces fixture references and decisions only.

The receipt records that the evidence contract checked out, the reviewed scope, the observed local head and the regulatory result. The result describes the authenticated assessment input. Company registration, corporate agency, source performance, enforceability and regulatory non-prohibition need evidence from competent independent sources for the specific activity. The port issues no legally effective determination. If authority evidence itself is unavailable, the review returns an authority error and yields no receipt.

## Concurrency and admission prerequisites

After evidence resolution the port compares the current local Log head with the snapshot head, and it checks expiry at the end of the review. Any intervening local append invalidates the review. Later mutations, stale peers, source-owner rollback and changes at independent evidence owners require additional fences.

These prerequisites for effective setoff remain open under [issue #299](https://github.com/larsbx/biz-kit/issues/299).

1. Define one versioned, domain-separated bilateral signed intent. Both independently authorized signers must sign the same canonical bytes. Bind the operator, principals and agents, both local member and agent key epochs, grant IDs and revisions, exact source IDs, source revisions and signed original hashes, parties, amounts and currencies, agreed rational rate and contract terms, exact reductions and residuals, evidence scope and versions, intent ID and expiry. The v1 consent carries no epoch binding.
2. At the existing serialized append gate, recheck the current signatures, authorities and epochs, expiry, jurisdiction assessment validity, source records, openness and prior reservations. Pin revocation and regulatory freshness to a transactional version or an independently governed freshness fence that orders changes against admission. Preflight reads and network calls outside the gate cannot supply that ordering by themselves.
3. Atomically claim both exact sources and the intent ID with the single canonical business event. Define idempotency on retry, overlap exclusion, recovery from ambiguous commits and restart/replay. Prove behavior for competing writers and for revocation before and during the commit. Close legacy aggregate execution for the new profile while preserving historical replay.
4. Establish the underlying commercial obligations and the contractual effect of setoff with independent jurisdiction-specific evidence before considering a production discharge. Accounting posting, external settlement, FX and custody are outside this port.

## Acceptance

The commercial clearing workflow includes the new signed-Log tests. They use synthetic authority and regulatory fixtures with actual signed source records. Controls cover revoked agents and grants, unknown status, exclusive expiry, grant scope and agent-key epoch, member-key rotation away and back followed by replay, same-value source substitution, incomplete or stale jurisdiction evidence, prohibition precedence and a signed source closure during evidence resolution.
