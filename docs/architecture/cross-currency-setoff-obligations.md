# Cross-currency setoff: remaining obligations

Reviewed: **2026-11-16 (America/New_York)**. Repository baseline:
`a95885edb78661ffb23921f5f039c634bed6d75b` on `main`.
GitHub observations were refreshed on 2026-11-17 UTC.

This is the living register for work after the exact-rational bilateral preview.
It records evidence and acceptance criteria; it authorizes no discharge,
accounting posting, payment, FX execution or favorable legal classification.
The supported participants remain two independent business principals, with
individuals acting only as authorized agents.

## Completed baseline and implemented drafts

The formerly pending scoped hosted checks for [PR #410](https://github.com/larsbx/biz-kit/pull/410)
have passed. #410 merged as `b2e0e6d87231e015970691306d47b667c44bd447`.
Those successful runs executed its branch head
`493c1fe35eabd4a6a31e1b5f66349a582cc23683`; they are not execution receipts
for that merge commit, current `main`, or a later integration.

| Work | Exact tested head | Observed scoped hosted evidence | Repository status at review |
|---|---|---|---|
| Proof-gate corrections, #410 | `493c1fe35eabd4a6a31e1b5f66349a582cc23683` | [Formal: 33 stages](https://github.com/larsbx/biz-kit/actions/runs/43585656752); [Barter: 72 tests](https://github.com/larsbx/biz-kit/actions/runs/43585656766); [commercial: 72 pure / 67 signed-ledger tests](https://github.com/larsbx/biz-kit/actions/runs/43585656909). All passed. | Merged. The earlier queued-check obligation is complete for this head. |
| Read-only canonical local source snapshot, [#413](https://github.com/larsbx/biz-kit/pull/413) | `ff28ac3c84d9b297664f01101424463b3e5a26fb` | [Formal: 33 stages](https://github.com/larsbx/biz-kit/actions/runs/43751546359); [commercial: 72 pure / 74 signed-ledger tests](https://github.com/larsbx/biz-kit/actions/runs/43751546452). All passed. | Implemented on an open draft, not merged. |
| Read-only business-authority evidence port, [#422](https://github.com/larsbx/biz-kit/pull/422) | `7a21e603e7aef6d5319271e26191c65de4d4f544` | [Formal: 33 stages](https://github.com/larsbx/biz-kit/actions/runs/43861943071); [commercial: 72 pure / 82 signed-ledger tests](https://github.com/larsbx/biz-kit/actions/runs/43861943089). All passed. | Implemented on an open draft stacked on #413's tested head, not directly on `main`. |

The formal jobs recorded clean-head passed receipts. Compilation and targeted
formatting also passed in the cited commercial jobs. The #422 PR body's **115**
local signed tests is a separately reported local result; the observed hosted signed suite
contains **82** tests. These are scoped successes, not a claim that every
repository workflow is green.

The accepted arithmetic baseline remains 40 model theorems, 40 separately
inventoried proposition contracts, an 80-declaration transitive axiom audit,
fresh replay of both modules with Lean's own kernel, 2,916 bounded
Lean–Quint–Elixir comparisons, and 992 Lean–Elixir boundary comparisons.
See the [proof bank](../../proof_bank/cross_currency_setoff/README.md).

The component boundaries remain distinct:

- The pure preview and its Lean record model consume host assertions.
- The merged consent slice verifies two signatures over its supplied commitment;
  it does not authenticate the underlying invoice or corporate appointment.
- #413 authenticates a current local signed Log prefix and reconstructs original
  source hashes and member keys. It remains a read-only local snapshot.
- #422 adds review of supplied authority/jurisdiction evidence and replayed key
  epochs. Its synthetic provider does not supply real-world trust roots, and
  its review does not add epoch binding to the existing v1 signed consent.

Exact-head specifications: [source snapshot ADR](https://github.com/larsbx/biz-kit/blob/ff28ac3c84d9b297664f01101424463b3e5a26fb/docs/architecture/2026-11-15-cross-currency-local-source-snapshot.md)
and [authority evidence ADR](https://github.com/larsbx/biz-kit/blob/7a21e603e7aef6d5319271e26191c65de4d4f544/docs/architecture/2026-11-16-cross-currency-authority-evidence.md).

## Ongoing acceptance of the inert preview

**CC-M1 — Preserve reproducible scoped acceptance.** When implementation,
configuration, proof, adapter or verification inputs change, execute the
relevant gates at the new actual head and retain the source manifest, runtime
identities, complete test inventories, comparison corpora and negative-control
logs. Preserve the 40-model/40-contract inventory and their axiom audit,
isolated fresh builds, source-specific mutation witnesses and explicit
development-mode labeling. Record the actual current suite size rather than a
historical constant. A previous head's success does not accept a new merge.

**CC-M2 — Review and integrate the existing inert draft stack.** Review #413
and #422 in dependency order; reconcile them with current `main` and inspect
the broader check results before merging either. Revalidate scoped acceptance
after changes to their tested heads or integration inputs. Keep the actual
checkout, local versus hosted results, and any inherited/introduced failures
explicit. These helpers already exist on the drafts; do not recreate them.
Merging this register does not approve or merge that implementation stack.

## Additional formal assurance

These are extensions beyond the current accepted pure-preview evidence.
They are **not newly imposed blockers for retaining the inert preview**.
Choose and review the intended stronger claim before expanding the model.

| ID | Remaining assurance | Evidence needed to claim it |
|---|---|---|
| CC-F1 | Universal implementation/model correspondence, including input guards | Specify the representation relation between actual Elixir inputs/results and Lean records. Cover accepted and rejected inputs, numeric bounds, rate direction, source identities, public-ID/currency syntax, dynamic-map shape and byte limits. Prove the claimed relation over its stated domain, or retain a narrower claim. Bounded comparisons alone do not establish it. |
| CC-F2 | Canonical commitment preimage encoding | Specify UTF-8 bytes, field order, length framing, domain/version separation and integer encoding. Prove decoder round-trip or injectivity over accepted canonical inputs and compare the actual encoder against it. SHA-256 collision resistance remains a cryptographic assumption; neither encoding nor hashing proves source authenticity. |
| CC-F3 | Temporal assurance for a later stateful protocol | First specify the actual transitions and trust assumptions. Then cover source/key/grant changes, expiry, intervening appends, competing writers, retries and restart/replay. State finite domains and exploration method, and connect the model to the real admission path. The current nine Quint source/agreement fixtures are not exhaustive protocol verification; no Apalache acceptance is claimed. |
| CC-F4 | More independent checker and runtime evidence, if pursued | Identify any independently implemented checker, its exact version, accepted proof scope and rejection controls. Separately document full runtime/library closure and authenticated runner receipts. Fresh Lean replay uses the same kernel implementation; existing receipts are unsigned and retain the documented runtime trust assumptions. |

## Prerequisites before future business effects

[P0 issue #299](https://github.com/larsbx/biz-kit/issues/299) remains open.
The following obligations apply to a future cross-currency admission/effect
path. Existing same-currency review and reservation code is useful prior work;
its schema and signatures cannot silently acquire cross-currency meaning.
Keep the existing canonical business Log as the admission point.

### CC-E1 — Independently governed authority and evidence

Supply reviewed providers and trust roots for distinct business registrations,
corporate appointments, issuer mandates, scoped grants, agent/member key
epochs, revocation, source performance and jurisdiction/activity assessments.
The #422 port defines an evidence contract; its synthetic adapter does not
fulfil this production obligation.

Acceptance must identify each competent evidence owner, exact source and act
scope, authenticated versions, validity/freshness rules and conflict handling.
Missing, unavailable, stale, revoked or mismatched authority must fail closed;
insufficient regulatory evidence must preserve `undetermined`. A successful
software fixture is not evidence that a real corporate or legal mandate exists.

### CC-E2 — Versioned bilateral signed intent

Specify and review one domain-separated cross-currency commitment signed by
both independently authorized principals/agents. Bind the operator, identities,
member and agent key epochs, grant IDs/revisions, exact source IDs/revisions,
original signed-core and full-record hashes with distinct names, parties,
amounts, both currencies, reduced quote/base minor-unit rational and direction,
negotiated contract terms, exact reductions/residuals, evidence scope/versions,
intent ID and expiry.

Acceptance must reject same-total source substitution, changed revisions,
noncanonical or inverted rates, changed terms, stale grants and rotation away
and back to the same key bytes. The v1 consent lacks epoch binding; a read-only
review of an epoch does not retrofit it into those signed bytes.

### CC-E3 — Revalidate and order authority at admission

At the existing serialized append gate, recheck the exact open sources,
reservations, signatures, current keys/epochs, authority and assessment
versions, and expiry. Define an adequate transactional version or independently
governed freshness fence that orders external revocation and policy changes
against the committing action.

Acceptance must exercise source closure, key/grant revocation and evidence
expiry before and during admission, unavailable evidence owners, stale peers
and source-owner rollback. Snapshot-head equality and preflight network calls
alone do not establish that ordering.

### CC-E4 — Atomic source/intent fencing and legacy compatibility

Atomically claim both exact sources and the intent with the single canonical
business event; distinguish an inert reservation from actual discharge. Define
exact-retry idempotency, changed-byte rejection, overlap exclusion and recovery
after an ambiguous commit. Demonstrate the protected profile's closure of
applicable legacy aggregate execution while preserving old signed history.

Acceptance must use the real storage/admission path for competing writers,
lost replies, partial failures, restart/replay and the independent-node fault
cases required by #299. No double use, partial source claim, duplicate effect
or reinterpretation of old signatures may be accepted. The existing
[same-currency work](https://github.com/larsbx/biz-kit/pull/392) is separate
evidence, not automatic acceptance of a cross-currency path.

### CC-E5 — Effective contractual discharge

Establish the underlying obligations, performance/title, mutual assent to the
exact valuation and partial release, agency, governing terms, conditions and
jurisdiction-specific effect through competent independent evidence. Record
what act makes the release effective and the approved production scope.

Acceptance requires a reviewed legal-effect and activity-specific
non-prohibition decision for the actual parties/operator and explicit owner
approval before enabling production discharge. Arithmetic, signatures, local
Log authenticity and evidence-contract validation establish separate facts.
Use the [protected discharge decision contract](commercial-discharge-decision-contract.md)
for its stated scope; its inert same-currency prototype is not an implemented
cross-currency discharge adapter.

### CC-E6 — Per-business accounting recognition

Separately authorize each business's functional-currency and carrying-value
treatment, applicable valuation differences, effective date and reporting.
Bind any journal to the actual legal-effect evidence and exact source
reductions. Preserve both original currency balances; do not create a scalar
total by adding unlike minor units.

Acceptance must demonstrate balanced, idempotent postings and retry/restart
behavior on the actual accounting integration. A preview or reservation
receipt is not an accounting entry.

### CC-E7 — Payment or FX capability only if separately requested

External payment, FX dealing, custody and transferable balances are separate
capabilities, not inevitable follow-ups to the preview. If proposed, obtain
their own reviewed operator/activity/jurisdiction determination, authority and
provider integration, with execution, reconciliation, failure and replay
acceptance. This register activates none of them and makes no favorable
legal determination.

## Next bounded milestone and closure rule

Review and integrate the existing **read-only #413/#422 stack**, preserving
its no-effects contract and refreshing evidence for any changed head.
The next new protocol specification is **CC-E2**, the versioned bilateral
signed intent, alongside the evidence/freshness design in **CC-E1/CC-E3**.
Actual discharge and accounting remain behind their separate obligations.

Close an obligation only with links to the reviewed artifact, its exact tested
revision and applicable receipts or independently authenticated decisions.
Record the scope and remaining assumptions. A merge, a test count, a local
snapshot or a signed assertion alone must not close a different claim.
