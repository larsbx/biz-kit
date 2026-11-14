# Cross-currency source provenance acceptance fixture

Status: proposed, test-only, inert. Publication and merge require owner approval.

## Purpose and inspected revisions

Exercise `BarterCore.CrossCurrencyConsent.verify/7` against independently
recomputed signed source history and current keys. Keep the original verifier's
cryptographic result separate from the fixture's synthetic authority inputs.

| Source | Inspected revision | Relationship |
| --- | --- | --- |
| `main` | `b9e3fd2062b933d7675c8398b7d47806b79da392` | Base for the proposed change |
| [PR #399](https://github.com/larsbx/biz-kit/pull/399) | `1b7665a503e0095adc45fba87a96cad51b5bf301` | Imports its four consent/description files; formats its new test |
| [PR #392](https://github.com/larsbx/biz-kit/pull/392) | `e19907e13937380278f58208be0213eef5deb0a1` | Inspected for interface boundaries; its schema and admission are not imported |

The original `CrossCurrencyConsent` implementation remains unchanged from
PR #399. This increment adds a test-only bridge and repairs four acceptance
gate defects. It adds no production event type, endpoint, command, appender,
reservation, accounting entry, currency exchange or discharge.

## Available interfaces and the missing authority interface

| Interface | Used for | Boundary |
| --- | --- | --- |
| `SignedConsumerSource.verified_head/0` | Signature and chain audit of a captured prefix | Local signed log; no external checkpoint freshness |
| `SignedConsumerSource.read_page/2` | Read the captured records | The fixture independently checks the returned page's count, order and chains |
| `Envelope.verify/1`, `event_hash/1`, `signing_bytes/1` | Verify authorship; distinguish full recorded event digests from signed-core digests | A signed invoice assertion does not establish real-world invoice validity |
| `Validity.check/2` and `AdmissionGate.handle_event/2` | Recheck historical authorization and reconstruct current state | Only an explicitly reviewed deterministic event vocabulary is supported |
| `CommercialSourceLineage.original_only?/3` | Refuse assigned, revised or closed original claims | Assignment away and back remains ineligible |
| `gate.members` and `commercial_admission.member_revisions` | Current keys and key epochs | Key registration does not establish corporate appointment |
| Signed `RoleKeyDeclared` / `RoleKeyRevoked` history | Authenticate the synthetic fixture reviewer's key and declaration epoch | The fixture uses a steward role; that role grants no real corporate-review authority |
| `CrossCurrencyConsent.verify/7` | Check two signatures on exactly the reconstructed source-bound terms | Its existing nonclaims remain unchanged |

`CommercialSetoffSources.snapshot/4` cannot directly supply this USD/EUR pair:
it requires bilateral sources in one denomination. It remains unchanged.

Current main's `CommercialAdmission` is a different proposal/reservation
contract from PR #392's `CommercialSetoffAdmission`. Neither is implicitly
extended by this fixture. On the inspected #392 revision, `current_evidence/4`
is private and bound to `CommercialSetoffAdmittedV2` and its same-currency
`terms_digest/3`. It expects two corporate-grant attestations and a separate
non-prohibition attestation from registered reviewers. There is no reusable
public cross-currency corporate-grant service to call on current main.

Accordingly, this fixture exercises synthetic detached corporate attestations
under a separately identified test policy. It does not claim to connect a
production corporate-authority registry that does not yet exist.

## Test-only integration

The bridge lives in
`apps/coop_substrate/test/support/cross_currency_provenance_fixture.ex`.
The corresponding `barter_core` dependency is `only: :test, runtime: false`.
No production application loads this bridge.

### 1. Capture and independently replay the bounded prefix

The fixture requires an independently supplied governance key pin, captures the
actual log's head, calls `SignedConsumerSource.verified_head/0`, and reads at
most 64 records. It verifies all of the following over the records it consumes:

- Exact record count and contiguous global sequence.
- The canonical stream identity, sequence and previous hash for every stream.
- Global previous hashes and equality with the captured final head digest.
- Every signed envelope, using the actual canonical encoder and Ed25519 verifier.
- Historical `Validity.check/2` before each `AdmissionGate` fold.
- Equality of replayed state with the current `Log.gate`.
- The target chapter's pinned genesis declaration and an unchanged final head.

The reviewed event vocabulary is role declaration/revocation, member
registration/rotation, entity registration, original obligations, assignment,
and direct obligation discharge. Other event types and larger histories are
refused. This is an acceptance fixture, not a general ledger export service or
an efficient production history reader.

### 2. Derive source facts and keys independently of the proof

For both selected obligations, the bridge requires one original
`ObligationRecorded`, open state, original-only lineage, revision 1 and initial
stream sequence 1. It compares source ID, debtor, creditor, amount and currency
with the actual signed event and current projection. It refuses a source that
has an existing reservation.

The source digest passed to `CrossCurrencyConsent` is the **full recorded
event hash**, including signatures and log placement. The fixture separately
recomputes the original signed-core digest and compares it with
`CommercialSourceLineage`. These two hashes are not interchangeable. In
particular, main's separate zero-based `CommercialAdmission.sources.revision`
is not substituted for the original-lineage revision used by this fixture.

Current member key IDs and public keys come from replay. No proof-supplied
key registry, fabricated digest map or cached source snapshot substitutes for
the fresh read. The source's eligibility, expiry and documentary reference
remain host assertions; `ObligationRecorded` does not authenticate those facts.

### 3. Check separately signed synthetic grant attestations

The fixture-only grant schema is
`bizkit.test.cross-currency-corporate-grant.v1`. Its Ed25519 signing domain is
`biz-kit/test-fixture/cross-currency-corporate-grant/v1\0`. A grant binds:

- Chapter, business principal and exact consent commitment, including its rate
  and negotiated terms.
- Current member key ID, public key and key revision.
- The steward issuer's key and the exact latest declaration event ID/hash.
- A visibly synthetic documentary reference and explicit validity interval.

Two different current steward keys must sign the two grants. They must also
differ from both party keys. Removing an issuer through real signed
`RoleKeyRevoked` makes its detached grant unusable. Redeclaring the same key
does not restore a grant bound to the old declaration. Member rotation away
and back likewise requires renewed evidence even if the public key is again
identical.

This demonstrates issuer-role revocation and fixture grant freshness. It does
not implement an independently authenticated corporate-mandate registry or
individual corporate-grant revocation. The fixture does not import PR #392's
reviewer role, legal attestation, event schemas or reservation mechanism.

### 4. Retain separate evidence meanings

The receipt preserves the original consent result and adds a separate
`fixture_evidence` map. Successful verification still reports:

| Field | Meaning |
| --- | --- |
| `status: :inert_cryptographic_consents_only` | Both parties agreed to the reconstructed bytes |
| `source_authentication: :external_not_verified` | Original pure verifier's claim is preserved |
| `fixture_evidence.source_history: :authenticated_local_test_prefix` | The fixture independently authenticated the synthetic scenario through real log interfaces |
| `fixture_evidence.actual_corporate_authority: :unverified` | No genuine corporate mandate was established |
| `fixture_evidence.real_world_invoice_validity: :unverified` | Signed records do not establish the underlying commercial facts |
| `fixture_evidence.legal_classification: :undetermined` | No legal/non-prohibition classification was issued |
| `admission: :not_authorized` | No append authority |
| `source_reservation: :none` | No durable source claim |
| `accounting_posting: :none`, `discharge: :not_executed` | No financial journal or effective discharge |
| `currency_exchange: :none`, `financial_settlement: :none` | No exchange or payment operation |

Head equality detects an intervening append during verification. A later
append remains possible. The fixture has no atomic admission fence and no
independently anchored freshness proof. A complete database rollback followed
by restart is outside this local-prefix check's guarantee.

## Adversarial acceptance

The 20-test suite covers:

1. Authenticated source digests, fresh keys and explicit inert result fields.
2. A fabricated source hash re-signed by both parties: pure consent succeeds,
   while fresh source-provenance verification refuses it.
3. Re-signed invented source IDs, amounts, currencies and revisions.
4. Assignment away and back, preserving visible parties but changing lineage.
5. Actual issuer-role revocation and revocation followed by same-key redeclaration.
6. Member-key rotation and rotation away and back, including successful renewed
   consent/grant evidence where applicable.
7. Changed negotiated terms, stale signatures and stale grant scope, followed
   by a correctly renewed positive control.
8. Missing, malformed, wrong-subject, tampered or nonindependent grant evidence.
9. Exclusive grant expiry and future validity intervals under a controlled clock.
10. Missing or substituted governance pins and malformed verification requests.
11. Stored signature and unsigned log-placement tampering, with original bytes
    restored before the test exits.
12. A deterministic intervening append, real log restart, unsupported event
    vocabulary, and the positive 64-record / negative 65-record boundary.

Ordinary positive and negative calls compare the complete log head and gate
before and after verification. The explicit race test supplies a test callback
that appends an unrelated member registration and must be refused.

## Hosted baseline: introduced and inherited failures

At the inspected #399 head, the
[Barter job](https://github.com/larsbx/biz-kit/actions/runs/43573974982/job/132384082025)
passed 72 tests, then failed formatting in the new consent test. Its separate
[commercial signed-ledger job](https://github.com/larsbx/biz-kit/actions/runs/43573974960/job/132384082123)
passed 43 tests. The
[Consolidation job](https://github.com/larsbx/biz-kit/actions/runs/43573974928/job/132384083860)
tested synthetic merge `cfb6f63feb96c27f7ec6b8ff551a2f295da717f0`, with
787 tests and one failure: the new direct Ed25519 site was absent from the
reviewed signing-domain inventory. Formatting and the inventory omission were
introduced by #399 and are repaired here.

The cross-currency workflow failed on both
[#392](https://github.com/larsbx/biz-kit/actions/runs/43404942368) and
[#399](https://github.com/larsbx/biz-kit/actions/runs/43573974914) because the
receipt checker demanded exactly 55 Barter tests. Their actual passing suites
contained 62 and 72 tests respectively. The verifier blob was identical on
both PRs and inspected main:
`9e27e4d7e0de2a0496c53e76aea7faff4d8e3257`. This is inherited acceptance-tooling
failure. The prior Lean/Quint/arithmetic stages passed; the overall workflows
remain failed.

This change replaces the fixed count with a structured ExUnit receipt from
the ordinary unfiltered test run. Acceptance requires every declared test to
start and pass once, coverage of every test file, a completed nonempty suite,
and no skipped, excluded, failed, interrupted or invalid tests. Receipt guard
tests reject missing, duplicate and substituted inventory entries.

Once the fixed-count check was repaired, the full local runner exposed a
second inherited failure: its final format-only audit compared the current
`commercial_setoff_proof_test.exs` with a historical assertion using
`length(ctx.proof.commitment)`. Current main had already corrected this to
`byte_size(ctx.proof.commitment)`, because the commitment is a binary. That
test file is unchanged by this proposal. The historical guard now explicitly
accounts for that one reviewed assertion correction while retaining strict
AST equality for every other expression and file, with negative controls
against unrelated changes. It is a formatting audit with one documented
preexisting assertion correction, not an unrestricted semantic exception.

PR #392's
[signed ledger job](https://github.com/larsbx/biz-kit/actions/runs/43404942271/job/131816882059)
passed 53 tests, and its signed-replay workflow passed its seven tests twice.
Those results do not validate cross-currency admission, and that PR was
conflicting with main when inspected.

## Reproduce

Use Elixir 1.19 / OTP 27 and an isolated PostgreSQL test database. The existing
CoopSubstrate test alias resets its configured test EventStore. From the root:

```sh
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors
cd apps/coop_substrate
BIZKIT_BUNDLED_TEST_LOCALE=true MIX_ENV=test mix test \
  test/cross_currency_provenance_test.exs \
  test/commercial_setoff_test.exs \
  test/commercial_setoff_proof_test.exs \
  test/commercial_setoff_sources_test.exs \
  test/commercial_setoff_intent_test.exs \
  test/commercial_source_lineage_test.exs \
  test/netting_execution_test.exs \
  test/obligation_rail_test.exs \
  test/signing_domain_test.exs
```

The existing commercial acceptance workflow now includes the new suite and
signing-domain guard. Its checkout explicitly uses the PR's head SHA.
The standalone Barter suite and receipt guards are:

```sh
cd apps/barter_core
mix test
mix format --check-formatted 'lib/**/*.ex' 'test/**/*.exs'
cd ../..
python3 -m unittest discover -s proof_bank/cross_currency_setoff/tools \
  -p 'test_receipt_guards.py'
```

For the complete arithmetic proof, use the pinned Lean/Quint versions and
the clean-head command in
`.github/workflows/cross-currency-setoff-proof.yml`. That proof is scoped to
preview arithmetic and asserted-record consistency, not this fixture's
corporate evidence or real-world legal validity.

## Local evidence and next review gate

Local execution passed 20 provenance tests and the combined 67-test commercial
regression/signing-domain suite. The standalone Barter suite passed 72 tests;
the structured receipt guards passed 11 tests. Actual formatter controls
accepted a healthy run and refused failed, skipped, excluded and empty runs.

The signed-log run used a narrow 16-app source harness, PostgreSQL 17.11,
Elixir 1.19.0 and OTP 27. Exact source versions of `ex_money` 6.3.0 and
`localize` 1.7.0 compiled, with the current lockfile preserved. The local
command used `--no-deps-check` because cached source copies lacked Hex install
metadata. A previously compiled canonical encoder was reused after matching
its Rust source and lockfile; its SHA-256 is
`ded4d95b807817705a41377422756043062cd5c64686deffd01c2a17f45babf2`.
This is qualified local evidence, not a fresh exact-locked umbrella build or
the hosted PostgreSQL 16 gate.

The next review gate is owner approval to publish this proposed change, then
the hosted workflows at the actual published head. Merge and deployment are
separate decisions. No successful hosted acceptance is claimed for these
unpublished changes.
