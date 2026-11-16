# Protected commercial proposal admission — 2026-11-09

Status: **reviewable implementation; inert proposals and operational source
reservations only**. This change does not enable discharge, accounting
recognition or financial settlement. Deployment and profile activation are
separate operator decisions. No production profile is activated by installing
this code or running its disposable acceptance fixtures.

Tracks [P0 #299](https://github.com/larsbx/biz-kit/issues/299), follows merged
[PR #344](https://github.com/larsbx/biz-kit/pull/344), and keeps open provenance
[PR #345](https://github.com/larsbx/biz-kit/pull/345) separate. The implementation
base is `47966dc9c46ead61cca0099076e77d3eb4801756`, the #344 squash merge.

## 1. The boundary being closed

`NettingExecuted` signs aggregate directional amounts, not the exact source
claims it subsequently closes. V1's `CommercialSetoffIntentRecordedV1` binds
current source IDs and terms but is a proposal: it does not replace the legacy
execution route. Direct `ObligationDischarged` and `ObligationAssigned` are
additional ways to close or move those claims.

The new `CommercialAdmissionProfileActivatedV1` event permanently selects
`source_bound_proposal_v2`, version `2`, for one chapter. The chapter selection
is reconstructed from its signed ledger history. A caller cannot opt out by
omitting a profile, naming a legacy version, selecting another request format,
or sending directly to `Log.append/2` or `Log.append_if/3`.

Activation requires exactly one explicitly declared current governance signer
and binds that declaration's event ID and full record hash. Bootstrap's generic
undeclared-role permissiveness does not authorize activation. A held activation
signed before revocation cannot become valid after the same key is redeclared.
Unknown profile/version values and repeated activation are refused. There is
no downgrade or deactivation event.

Once activated, all **new** instances of these types in the chapter are refused:

| Type | Reason for fencing |
| --- | --- |
| `NettingExecuted` | Aggregate signatures cannot authorize exact source mutations. |
| `ObligationDischarged` | Direct closure would bypass the protected admission contract. |
| `ObligationAssigned` | Moving a claim out of a pair and back must not bypass protection. |
| `CommercialSetoffIntentRecordedV1` | Newly protected proposals must use the versioned source and authority bindings. |

The choice is intentionally chapter-wide and conservative. Ordinary original
`ObligationRecorded` events remain subject to their existing two-party,
current-key and exposure-cap checks. A chapter without an activation retains
its existing admission behavior. This is a **selective protected-profile
fence**, not a claim that every legacy chapter is protected.

## 2. The new inert event

`CommercialSetoffIntentReservedV2` requires exactly three differently keyed
signatures: current `party_a`, current `party_b`, and current `governance`.
Different signing keys do not establish different legal persons or corporate
agency. All signatures cover the same canonical envelope core, including:

| Binding | Signed fields and validation |
| --- | --- |
| Scope and version | Envelope chapter; profile name/version; exact activation event ID and full hash. |
| Intent | Unique chapter-qualified intent ID; envelope event ID. |
| Pair and denomination | Ordered distinct participant IDs; one uppercase three-letter denomination. |
| Current participant authority | Current member key IDs/public keys in the signer list; current monotone key revisions in the payload. |
| Current governance authority | Current declared key and the exact declaration event ID/full hash. |
| Every source | Obligation ID, debtor, creditor, amount, denomination, original event ID/full hash, source revision, latest event ID/full hash. |
| Complete set and figures | Complete sorted list of all current open pair obligations in that denomination; list digest; exact directional totals and setoff. |

The maximum list length is 256. Amounts and aggregate directional totals must
be positive and fit signed 64-bit minor-unit bounds. Floating-point conversion,
mixed-currency setoff, subset selection and duplicate sources are not admitted.
The list digest is redundant consistency evidence; it does not replace signing
the complete source rows. Identical totals do not make different claims equal.

`CommercialAdmission.prepare/6` builds a signing payload from a gate snapshot.
It is read-only and conveys no append permission. The current profile, source
set, authority, intent and reservation checks run again inside the canonical
appender. No caller-provided `verified`, corporate-agent, legal-eligibility or
financial-authority flag is accepted by the event schema.

## 3. Full-record provenance and revision semantics

The authoritative `AdmissionGate` has a new `commercial_admission` read fold.
Its source metadata is reconstructed from the existing canonical business
stream. It is not a new event store, financial writer or balance ledger.

`Envelope.event_hash/1` covers the canonical **full record**: signed core,
signature set and assigned stream/global chain fields. The original event's
signatures authenticate its core. The new proposal signatures additionally
bind the exact full-record hash identified in the verified local history.
Copying a caller's digest into a payload cannot create provenance.

An original `ObligationRecorded` starts at revision 0. Historical assignment,
direct discharge and legacy netting increment the affected source revision
and replace its latest-event reference. Any such mutation permanently clears
`original_only`. Assignment out and back cannot restore eligibility, even when
the final parties and amounts equal the original values. Legacy netting
residuals are marked derived and ineligible.

This bounded V2 profile accepts only current open **unmodified originals**.
It deliberately refuses assigned/derived lineage rather than claiming a
complete authenticated assignment-chain implementation. Future lineage
support requires a separately reviewed source contract and must retain the
same original reservation identity.

Open PR #345 tracks **signed-core** digests in a Membership read projection.
Those values are useful but differ from full log-record hashes. This change
neither merges that PR nor substitutes its digest for the V2 binding. The two
read projections derive from the same stream and can coexist; their names and
digest definitions must remain distinct.

## 4. Admission, atomicity and recovery

The canonical append sequence is:

1. Validate the raw envelope/schema/signature set, verify every signature,
   and reject caller-assigned chain fields or duplicate batch event IDs.
2. Recognize an exact previously accepted singleton V2 request as a historical
   receipt. A changed payload reusing that event ID is refused.
3. Tentatively assign chain fields to the whole batch as a pure calculation.
4. Check each event against the gate left by its predecessors in that batch.
   The profile fence, current authority, full source binding and conflict
   checks occur here. Any refusal aborts the entire batch.
5. Encode and atomically append to the existing physical `ledger` stream at
   its expected version. Only a successful store compare-and-append publishes
   the new gate and returns an admission receipt.

Tentative assignment before validation is needed because a full-record hash
includes assigned chain fields. Validation, successful final folding and
restart replay now see the same record representation. A failed batch does
not publish tentative provenance, reservations or a profile activation.

Reservations map `(chapter, original obligation ID)` to the admitted intent.
Revision numbers and amounts are **not** reservation keys. A second intent
touching any reserved source is refused. Two overlapping proposals in the
same batch cause the whole batch to fail. Two independently prepared appends
through one appender admit at most one. Two appender processes with the same
store version cannot both append: the losing process stops on
`wrong_expected_version` and its replacement recovers the winner's state.
V2 also refuses an intent ID already present in the historical V1 proposal
projection. Migration requires a fresh intent ID; it never upgrades a V1
proposal into a reservation implicitly.

Restart first verifies the existing chains, then reconstructs the profile,
provenance, authority epochs, intent identities and reservations from the
canonical ledger. Historical legacy and V1 events keep their old folds. New
admission rules are not retroactively applied to old events, and later key
revocation does not erase a historical proposal or its reservations.

An exact singleton retry returns the same stored event and leaves the head
unchanged, including after restart or authority revocation. That response is
evidence of a past admission, **not** fresh authority to perform an effect.
Changed event/intent requests do not receive that shortcut. No reservation
release or expiration transition exists in this increment; operators must
account for this deliberate liveness restriction before activating a chapter.

The generic `Commands` preview currently folds Membership and cannot simulate
new commercial substate changes across an unsigned batch. The commercial
preparation API and authoritative Log path are the supported V2 route; a
preview never bypasses the actual append checks.

## 5. Authority and effect remain separate

| Claim | This increment establishes | Remaining independent requirement |
| --- | --- | --- |
| Registered signing authority | Current member keys/revisions and an explicitly declared current governance key/declaration at serialized admission. | Authenticate a business principal and its agent, grant scope, expiry and revocation from a trusted corporate-authority adapter. |
| Source-record identity | Exact verified local record hashes, terms and unmodified-original revisions. | Authenticate invoices, ownership, performance and any external or assigned source lineage. |
| Proposal conflict protection | One durable reservation per exact original source, in the existing journal. | Separately specified cancellation/release and any eventual source-consumption transition. |
| Contractual discharge | None; obligations remain open. | Authentic governing contractual terms and current authority for any legally effective release. |
| Accounting recognition | None; no balances or accounting entries are posted. | Business-specific recognition and posting rules plus authorization. |
| Financial settlement | None; no custody, transferable credits, Hawala, bank or crypto effects. | Separate provider authority, finality and reconciliation. |
| Regulatory classification | None inferred from signatures, proofs or tests. | Scoped operator/activity/jurisdiction analysis as already required by #299. |

Governance declarations here have ledger-ordered revocation, not corporate
grant validity intervals. Author-asserted timestamps are not a trusted expiry
clock. Those limitations are compatible with an inert proposal but cannot be
promoted into contractual or financial permission.

## 6. Lean-first and independent Quint evidence

The Lean model `BizKitCommercialAdmission.lean` states universal conditional
invariants over arbitrary finite source lists: monotonic profile protection,
legacy refusal, exact source and authority binding, rejection stuttering,
exclusive immutable source reservations, inert effects and recovery folds.
Its fixed theorem inventory, compiled axiom audit, intentionally false theorem
controls and fresh same-kernel replay are checked by
`formal/lean/check_commercial_admission.sh`. The only allowed axiom dependencies
are `propext`, `Classical.choice` and `Quot.sound`.

The separately authored `commercial_admission.qnt` models finite source/pair
scopes, durable journal replay, prepared workers, authority changes and
store-version contention. Its runner requires deterministic positive/refusal
scenarios, seeded simulations, an explicitly bounded symbolic slice, and a
distinct real invariant counterexample for each weakened guard. Parser
failures, timeouts and generic nonzero exits do not count as counterexamples.
Retained logs and ITF traces identify the exact model and checker hashes.

The Quint runner requires Quint 0.33.1, Apalache 0.62.4 and Temurin Java
21.0.13+9 on `PATH`. Apalache uses Java 21 class files; the hosted image's
default Java 17 cannot load it. The workflow installs the pinned JRE, and the
runner records and verifies its version before any acceptance stage.

These models are not a mechanized refinement proof of Elixir/PostgreSQL or a
cryptographic proof. Hash collision resistance, truthful source authentication,
the signature verifier, store durability and the model/runtime correspondence
remain explicit boundaries. Bounded checks are not unbounded or exhaustive
distributed fault verification. No proof establishes corporate agency or
regulatory compliance.

## 7. Reproducible runtime acceptance

The dedicated `Protected commercial admission acceptance` workflow checks out
the exact PR head. Its signed-ledger job depends on both formal jobs. It uses
OTP 27.3.4, Elixir 1.19.0, locked Mix dependencies and PostgreSQL 16, requires
warning-free umbrella compilation and targeted formatting, and retains source
hashes, head/tree identity and test logs as workflow artifacts.

The new signed-log tests cover exact full hashes, same-total identity
substitution, revision/hash changes, assignment out-and-back, invalid versions,
profile activation/revocation, member-key restoration, governance-key
revocation/redeclaration, conflicting proposals, atomic rollback, simultaneous
callers, competing appender processes, lost-reply retry and restart replay.
Positive and negative same-batch source tests exercise tentative provenance.
Historical V1 and legacy netting behavior is checked explicitly.

Existing commercial, obligation, canonical-log, key/role recovery, cluster,
procurement and group-buy tests are included because the append ordering is a
shared boundary. These are scoped runtime observations, not a claim that every
repository workflow or every network/power-failure scenario passed.

Local commands, with the pinned tools available:

```sh
bash formal/lean/check_commercial_admission.sh
bash formal/quint/check_commercial_admission.sh
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors
cd apps/coop_substrate
MIX_ENV=test mix run --no-start \
  -e 'Application.put_env(:localize, :otp_app, :localize, persistent: true); Mix.Task.run("test", System.argv())' -- \
  test/commercial_admission_test.exs test/commercial_setoff_intent_test.exs \
  test/netting_execution_test.exs test/obligation_rail_test.exs test/log_test.exs --seed 0
```

Use the workflow for the complete regression command and evidence artifacts.
Record observed exact-head results in the PR; do not treat this specification
or a queued run as a passing receipt. Keep #299 open for the remaining
contractual authority, legal discharge, accounting and settlement boundaries.
The branch is for review and must not merge or activate automatically.
