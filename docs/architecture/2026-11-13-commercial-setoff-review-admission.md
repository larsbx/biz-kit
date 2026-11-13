# Source-bound commercial setoff review

Issue [#299](https://github.com/larsbx/biz-kit/issues/299) tracks the route from exact-source consent to commercial accounting admission. This increment records a signed review receipt and reserves its sources in the canonical business ledger. The accounting result is a proposed same-currency setoff and residual. The obligations remain open, with no journal posting, contractual release, payment instruction, or external settlement.

## Signed records and append order

1. Chapter governance declares reviewer keys in the existing role registry. A currently registered governance key signs `CommercialSetoffReviewProfileEnabledV2` to opt the chapter into review. This is a chapter-wide, irreversible fence on new aggregate `NettingExecuted` appends. Historical events still fold under their original semantics.
2. `CommercialSetoffAdmission.terms/5` builds the complete current same-currency bilateral source set, sorted by obligation ID. Each row binds the original signed-core digest, lineage revision, amount, currency, debtor and creditor. The terms also bind the intent ID, directional totals, setoff and signed residual. A positive residual is owed by party A to party B.
3. Each reviewer signs a `CommercialSetoffReviewEvidenceRecordedV2` citing the versioned terms digest, a documentary record digest, the subject and a validity window. The terms digest includes the chapter and both current member key identities and replay-derived rotation epochs. Corporate-grant attestations are specific to a party and intent. The non-prohibition attestation is specific to the chapter and intent. Governance can revoke evidence, and revoking a reviewer key permanently invalidates evidence signed by it.
4. The participants sign a single `CommercialSetoffAdmittedV2` containing the full terms and the exact three evidence event IDs. The append gate recomputes terms against its current fold, matches both current participant keys, and checks the admitted evidence, time windows and registered reviewer keys. It requires five distinct public keys. Original-only eligibility uses the existing irreversible lineage projection. A restored debtor, a closed source and a derived legacy residual fail eligibility.
5. One expected-version write commits the receipt and its source reservations. Exact signed retry returns the original receipt, including after revocation or restart, because it creates no new claim. Competing intents, source assignment and direct discharge of a reserved source are refused. The reservation is permanent in V2. This review profile is for isolated acceptance until a release policy and operational rollout are approved.

All appenders sharing a ledger must understand V2 before any review profile is enabled. The expected-version fence protects writers sharing the canonical store. Independent stores or old writer binaries require separate rollout and fault acceptance.

## Evidence and review boundary

The reviewer registry is a trust anchor. Key separation verifies distinct signing keys. Governance and external reviewers must establish independence of the people and companies, authenticate corporate authority and trade evidence, and retain the documents matched by the digests. The non-prohibition record must identify the jurisdictions, parties, transaction, scope, applicable restrictions, rationale, reviewer and review window. V2 verifies the signed reference and its scope. It does not independently validate the referenced document, sanctions decisions, or legal effect. A legal or policy determination remains separate from the accounting review receipt and from Hawala, bank or other settlement finality.

The Lean model proves reservation and refusal properties over finite source lists with abstract freshness and term-equality premises. The bounded Quint model exercises reservation, revocation, irreversible reassignment, restart and the live legacy fence. The signed Elixir acceptance tests exercise the actual log and replay. These are three independent forms of evidence. No runtime refinement or jurisdiction-specific determination is claimed.

## Reproduce

Use the [commercial clearing acceptance workflow](../../.github/workflows/commercial-clearing-acceptance.yml) with PostgreSQL and the pinned BEAM toolchain. The dedicated tests cover identical-total substitution, modified source revision and commitment, assignment out and back, evidence revocation and expiry, key rotation, concurrent and stale writers, exact retry, restart and historical aggregate replay.

Run `formal/lean/check.sh` with the repository's pinned Lean toolchain. For Quint 0.32.0 run:

```sh
quint typecheck formal/quint/commercial_setoff_review.qnt
quint run formal/quint/commercial_setoff_review.qnt --invariant=safety \
  --max-samples=10000 --max-steps=20 --seed=1
```
