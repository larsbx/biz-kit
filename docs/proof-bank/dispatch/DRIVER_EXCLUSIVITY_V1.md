# Driver exclusivity: review proposal for #296

Source baseline: `fd0e5cc20335ab58e5ccd3f39463c63897c4d585` (main inspected
2026-11-05). Status: **hosted model, runtime and candidate evidence passed at `c9f30a38`;
E2/E3 remain proposals and no implementation refinement is proved**.
See the pinned execution receipts below.
No operational code or migration is changed by this review packet.

## Exact-source findings

All links below are to the inspected revision, not moving main.

| Source | Evidence and implication |
| --- | --- |
| [Assignment](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch/fleet/assignment.ex#L29) | Attribute tenancy; participant UUID; private, non-null exclusivity flag; partial identity; plan accepts role argument, but no status/flag input. Activate/complete/cancel are callable Ash updates without resource policies or Board's source-state guards. |
| [Migration](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/priv/repo/migrations/20260918143025_loads_stops_and_parties.exs#L122) | Unique `(tenant_id, operator_participant_id)` WHERE `status = 'ACTIVE' AND operator_exclusive`. No time-window predicate or operator participant FK in this migration. No later assignment-index change was found in the migration inventory. |
| [Participant](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch/accounts/participant.ex#L1) | A global user can have two organization-specific participants. Active participant uniqueness does not identify a human across assignments or prevent re-enrolment after closing a participant. |
| [Organization](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch/accounts/organization.ex#L1) | Organizations are global; an organization is an operating tenant. Organization kind is not authorization. |
| [Board](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch/operations/board.ex#L200) | Locks the selected trip, then fresh dispatcher authority, rereads trip ownership/version/source state, checks current driving role, updates and audits in one transaction. Distinct trips have distinct row locks. No global-user lock or count. Response reload follows the transaction. |
| [Driving](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch/access/driving.ex#L43) | Activation share-locks operator role rows; driving authority is capability-based. These compatible locks do not arbitrate two activations. Equipment check-in/revocation is a separate obligation. |
| [Profile derivation](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch/fleet/changes/derive_operator_exclusivity.ex#L40) | Reads a tenant-scoped role/profile but does not compare its principal with the trip's operator. An unrelated allowlisted concurrent profile can therefore relax the stored flag through direct Ash planning. Current production profiles default to exclusive; the witness uses the existing test Courier, so this is a conditional extension-path defect, not an observed production exploit. |
| [HTTP writes](https://github.com/larsbx/biz-kit/blob/fd0e5cc20335ab58e5ccd3f39463c63897c4d585/apps/dispatch/lib/dispatch_web/controllers/operations_controller.ex#L154) | Delegates planning and transitions to Board; Board planning chooses the organization's driver's actual role rather than accepting a caller-chosen role. |

## Invariants to review

**E1 (present database property).** In every committed database state, for
any key `(tenant, operator_participant_id)`, at most one assignment has
`status=ACTIVE AND operator_exclusive=true`. This ranges over all trips and
loads within the key, independent of carrier filter or writer. PostgreSQL's
unique index arbitrates even when the rows being updated are distinct. A
preflight count or additional trip lock is unnecessary for E1. A stale-version
check alone cannot prove E1 across trips. Existing deployed index presence is
an assumption until checked against that database.

**E2 (stronger compatibility proposal).** For one identity key, if either of
two ACTIVE assignments requires exclusivity, they must not coexist. Two
explicitly concurrent profiles may coexist. E1 does not imply E2: one true and
one false row never conflict in the current partial index. Mixed-profile
semantics require owner review, not an unconditional index on all ACTIVE rows.

**E3 (global-user proposal).** For the initial DRIVER profile, use the global
Dispatch User ID across all tenant participants, including closed/re-enrolled
participants. Apply E2 using that key. User ID is only an account identity;
duplicate accounts for one human and external systems are outside this model.
E3 is a proposed policy, not established owner intent: current Section 22.2
and the schema specify operator participants. A cross-tenant refusal must
return a generic conflict without disclosing another tenant's trip or carrier.

Overlapping means simultaneous committed ACTIVE statuses for E1–E3, rather
than overlapping planned timestamps. Several PLANNED trips are allowed,
even with overlapping windows. Recorded nonoverlapping windows, a future start
or a past end do not free an ACTIVE slot. `Assignment.active`'s time-filtered
read is narrower than the index; it must not replace the invariant query.
COMPLETED/CANCELLED release a slot at commit. Rollback preserves the prior
slot and audit state. Direct Ash can currently reactivate terminal rows; E1
still constrains those writes, but Board's lifecycle/audit guarantees do not
extend to them. No proposed temporal scheduling exclusion is implemented.

## Supported writers and authority scope

- Public operations HTTP/portal writes enter Board with a selected actor;
  Board derives tenant and carrier, revalidates selected authority inside the
  transaction, and owns its lifecycle and audit checks.
- Direct Ash actions/code interfaces are internal callable writers with no
  equivalent resource authorization/source-state guard. They preserve E1 via
  the index, but are not approved substitutes for Board at an external boundary.
  Plan-time profile derivation needs its own provenance guard.
- Raw SQL, migrations and imports with table write privileges also encounter
  E1 if they leave the index and predicate columns intact. They can set the
  flag false and do not inherit Board audit/version/authority guarantees.
  No privileged-writer or database-administrator resistance is claimed.
- The source search found no other production Assignment status writer.
  Future jobs, bulk writes and integrations must enter the reviewed path or
  independently demonstrate every applicable obligation. This source inventory
  is not a theorem about future writers.

## Executable acceptance matrix

`apps/dispatch/test/dispatch/operations/board_driver_exclusivity_test.exs`
uses separately checked-out, unsandboxed committed PostgreSQL connections.
No shared Sandbox connection serializes the contenders. Barriers keep the
winning write uncommitted; `pg_blocking_pids` polling requires an actual wait
before release, rather than relying on sleeps. Post-state assertions use an
independent session. Explicit trip versions and audit counts are checked.

| Cases | Acceptance observation |
| --- | --- |
| Distinct trip A first and B first; commit and rollback | At most one exclusive ACTIVE row; loser remains PLANNED without audit/version increment; rollback lets contender commit. |
| Complete and cancel, commit and rollback | Contender waits; only committed terminal transition releases slot. |
| Stale version on a distinct trip | No slot, version or audit mutation. |
| Direct Ash and raw SQL competing with Board | Index conflict blocks and refuses the non-Board writer. SQL asserts PostgreSQL unique_violation. |
| Nonoverlapping recorded windows | Status-based conflict still applies. |
| Shared User across two tenants | Current-scope witness expects both commits; stronger acceptance switch deliberately fails. |
| Another participant's Courier role supplied to Ash plan | Conditional provenance witness expects false flag and mixed ACTIVE rows; stronger acceptance switch deliberately fails. |

Run using the existing `proof-bank-dispatch-pilot.yml` PostgreSQL/PostGIS 16,
OTP 27.3.4 and Elixir 1.19.0 setup (EventStore initialization and locked deps):

```sh
git rev-parse HEAD
cd apps/dispatch
MIX_ENV=test mix test --include integration test/dispatch/operations/board_driver_exclusivity_test.exs
# Proposed stronger requirements: expected red on the audited source.
DISPATCH_ASSERT_GLOBAL_DRIVER_EXCLUSIVITY=1 MIX_ENV=test mix test --include integration test/dispatch/operations/board_driver_exclusivity_test.exs
DISPATCH_ASSERT_BOUND_DRIVER_PROFILE=1 MIX_ENV=test mix test --include integration test/dispatch/operations/board_driver_exclusivity_test.exs
```

The normal suite characterizes current behavior, including limitations; green
does not accept E2 or E3. The switches are separate review probes. At `21923592`, the hosted ordinary suite executed all 14 exclusivity cases
within 61 integration tests, with zero failures. The two stronger-policy
probes produced their required assertion failures. These outcomes apply to
the disposable PostgreSQL/PostGIS CI database, not an inspected production
database. See the pinned hosted receipt for source and job identifiers.
The workflow now includes this file and triggers on fleet schema, migrations,
Driving and Participant changes as well as existing authority paths.

## Smallest corrections, isolated for review

For E1, retain the database index; do not add a race-prone count check.
`PROPOSED_BIND_OPERATOR_PROFILE.patch` is an **unapplied** minimal correction:
only a role naming this operator participant may relax exclusivity. Otherwise
keep the restrictive default. Run the bound-profile acceptance switch after
applying it. This closes the demonstrated foreign-principal branch only;
it does not establish role validity, carrier/scope binding, plan-to-activation
policy stability or E2/E3. A full provenance repair should validate a current
role for the operator in the load's carrier organization and preserve/recheck
the policy source under transaction locks. Those decisions need additional
expired/revoked/changed-role tests before adoption.

For E3 with all driver trips exclusive, a unique global identity key on ACTIVE
exclusive assignments is the database correction. It requires a trusted,
immutable `operator_user_id` populated from a tenant-matching Participant,
validated/backfilled before creating the global index; public callers must not
supply it. A join in an application count check is insufficient. PostgreSQL
cannot use a joined participant lookup in a simple index expression. Audit
existing duplicate active assignments before any migration; do not silently
cancel them. This changes cross-tenant behavior and is deliberately not applied.

If E2 must also hold, the simple unique partial index is insufficient. Consider
a database exclusion constraint on global identity equality and incompatible
policy modes (exclusive vs any active mode), or a transactionally maintained
claim relation. It must cover every approved writer and release atomically on
completion/cancellation/rollback. Define and test its SQL semantics separately;
no implementation or proven migration is supplied here. Global user locks plus
checks are safe only if all writers honor them; they are not a substitute for
a database constraint under the current raw-SQL writer boundary.

## Formal extension proposal, separate from runtime evidence

Keep `BizKitDispatch.lean`'s individual-trip results unchanged. A separate
candidate model should map TripId to (tenant, participant, globalUser,
policyMode, status, version), with an explicit trusted identity relation.
Define E1, E2 and E3 independently and prove preservation for plan, activate,
complete and cancel at committed-state boundaries. Activate must consult the
whole assignment map; a local trip guard cannot prove global uniqueness.
Model abort as no change and multi-write transactions as one atomic commit.
A bounded two-trip/two-tenant search should refute any version lacking the
global guard. Such a model would still not prove Ash/SQL refinement, index
installation, authority provenance, fairness, deadlock freedom, durable audit
ordering or correspondence across all writers. Keep #296 open.


## Execution receipt: 2026-11-05 continuation

[Hosted run 41977191093](https://github.com/larsbx/biz-kit/actions/runs/41977191093)
checked out exact source `f04dee6446b17cc0f8b5cc25bb23f6d8e3c67218`.

| Job | Observed result | What this establishes |
| --- | --- | --- |
| Formal (127078680813) | Success: Lean kernel replay/axiom audit and Quint bounded checks/negative controls | Existing individual-trip models replayed. No global-exclusivity theorem was added. |
| Portable linkage (127078680901) | Success | Existing portable review packet compiled, tested and found its source anchors. |
| Runtime (127078680995) | Failed at EventStore initialization compilation; database setup and integration tests skipped | No driver-exclusivity runtime result. PostgreSQL container startup and locked dependency installation succeeded. |

The compiler rejected `CommercialSetoff.prepare/6`'s bodyless default-argument
head because it contained `{a, b}` instead of a variable. The continuation
changes only that declaration to `pair`; the guarded implementation clause
still matches `{a, b}` and the fallback still refuses malformed requests.
This is a prerequisite compile repair, not an assignment policy correction.
The production exclusivity patch remains unapplied.

Local validation compiled the actual corrected module using a minimal Log
stub and exercised malformed-pair fallback through both prepare/5 and
prepare/6. This is an isolated compiler/API check: it does not exercise the
canonical Log, financial behavior, Ash, PostgreSQL or the concurrency suite.
A fresh hosted exact-source run is required after this compile repair;
previous formal/linkage success must not be relabelled as success at a later
revision. This earlier failure is superseded by the successful `21923592` run below;
keep #296 open for the remaining policy and correspondence work.


### Automated refutation controls

The two boundary witnesses have separate ExUnit tags. After the normal
integration suite succeeds, CI invokes
`scripts/dispatch/check-exclusivity-controls.sh` from `apps/dispatch`.
Each selected proposed requirement must produce ExUnit exit 2, exactly one
failure, and its specific exclusivity assertion text. A startup failure,
an unrelated assertion or an unexpectedly passing requirement fails this
control runner. This records current limitations; it does not adopt either
proposed policy. When a reviewed repair is implemented, promote its probe to
normal positive acceptance and retire the corresponding expected-red control.

Local runner self-checks used a synthetic `mix` command to confirm acceptance
of the intended assertion result and rejection of startup errors, unrelated
assertions and unexpected success. These self-checks validate only the shell
runner; the real PostgreSQL probes subsequently executed successfully at `21923592`,
as recorded below.

## Implemented abstract verification layer

The separate [Lean/Quint testbank](FORMAL_EXCLUSIVITY_V1.md) now implements the
fixed-identity abstract model proposed above, with committed-state preservation
proofs and finite counterexample controls. Its assumptions and local replay
receipt are separate from the PostgreSQL results and from owner acceptance of
E2/E3. The individual-trip model and operational exclusivity behavior remain
unchanged; no implementation refinement theorem is claimed.


## Hosted model/runtime evidence at `21923592`

[Run 42110873119](https://github.com/larsbx/biz-kit/actions/runs/42110873119)
ran the literal source revision `2192359288daab6291798619586f12b37e6b3f78`.
Formal (127537766923), portable-linkage (127537767353) and runtime
(127537767576) jobs all passed. The ordinary integration suite reported
**61 tests, zero failures**, including all 14 driver-exclusivity cases.
The stronger global-user and bound-profile runs each reported 14 tests with
one expected failure; the wrapper matched the specific assertion in each case.

Thus the supplied PostgreSQL cases now observe index arbitration for distinct
trips, commit/rollback, terminal slot release and non-Board writers. They also
observe the two-tenant shared account committing both ACTIVE trips and the
conditional unrelated-profile path relaxing the stored flag. These are
current-behavior witnesses; passing CI does not establish E2/E3 or deploy a
correction. The stronger probes intentionally remain red inside a runner that
recognizes the required failures. See
[the machine-readable hosted receipt](hosted_exclusivity_receipt_21923592.json).

This evidence does not establish every writer/isolation interleaving,
production constraint installation, authority/identity stability or the full
refinement claim. The later abstract admission-function linkage extension is
locally rechecked separately; success at `21923592` is not relabelled as a
hosted success at a subsequent source revision.


## Hosted continuation at `e1d81bfa`

[Run 42113640384](https://github.com/larsbx/biz-kit/actions/runs/42113640384)
ran literal revision `e1d81bfa8311bd401add967ae7b6db7a9d30d440`.
Formal, portable-linkage and runtime jobs all passed. Formal evidence includes
the admission-function linkage, fresh kernel replay, 114-declaration axiom
audit, 11 Quint directed tests and bounded depth-8 checking. Runtime again
reported 61 tests with zero failures, including all 14 exclusivity cases;
each stronger-policy probe produced its required assertion failure.
See [the pinned receipt](hosted_exclusivity_receipt_e1d81bfa.json).

## Review-only candidate patch experiment

`scripts/dispatch/review-profile-binding-patch.sh REVIEWED_SHA` requires a
literal 40-character lowercase SHA equal to HEAD and a clean checkout. It
runs against the already prepared disposable Dispatch test database, following
the ordinary tests and limitation controls. It establishes the foreign-profile
acceptance failure on the baseline, hashes the original source and reviewed
patch, temporarily applies that patch and requires all 14 cases to pass with
the bound-profile acceptance assertion enabled. Global-user behavior remains
the baseline policy during this experiment.

The runner restores the original file and force-recompiles Dispatch, including
on candidate failure. It fails if source/build restoration fails. Normal
completion also requires an unchanged HEAD and clean checkout. Its candidate
output refers to a **derived patched source**, not the unchanged commit SHA.
The candidate patch remains unapplied in the committed operational module.
The CI step is labelled separately from exact-source baseline acceptance.

Local shell/workflow syntax and synthetic runner tests passed. Synthetic
controls covered candidate success, candidate rejection, skipped cases,
unrelated startup errors, missing baseline refutation and restoration-build
failure. Revision/cleanliness guards refused invalid invocations; the actual
dirty checkout was also rejected before executing tests. These validate the
review runner, not PostgreSQL or the patch's real acceptance outcome. Hosted
candidate execution subsequently passed at `c9f30a38`, as recorded below.

For reproduction after checking out the reviewed source and preparing the
same PostGIS/EventStore/dependency setup:

```sh
bash scripts/dispatch/review-profile-binding-patch.sh REVIEWED_FULL_SHA
```

This candidate addresses only borrowing another participant's profile. It
does not resolve role expiry/revocation, carrier/scope binding, policy changes
between planning and activation, E2/E3 or the implementation refinement theorem.
No operational deployment, assignment correction or migration is authorized
by an expected-green candidate test.


## Candidate result and current-main integration (2026-11-06)

[Run 42220377524](https://github.com/larsbx/biz-kit/actions/runs/42220377524)
passed all three jobs at `c9f30a38ab36c9a534bc7f817b2b36a4fc658f3a`.
Formal accepted 114 declarations, 11 directed Quint tests and the required
negative controls. The ordinary PostgreSQL suite again passed 61 tests with
zero failures. The expected limitations remained reproducible.

The review-only patch step **also executed successfully on PostgreSQL**:
the bound-profile assertion failed once in 14 baseline cases, then all 14
cases passed with the exact reviewed patch applied. The runner restored the
original source, rebuilt Dispatch and passed its final exact-HEAD/cleanliness
checks. [The hosted receipt](hosted_exclusivity_receipt_c9f30a38.json) records
source, patch and derived-target SHA-256 hashes. This is evidence for that
minimal conditional correction in the supplied cases; it is not a claim that
the unchanged source passes the bound-profile requirement.

The review branch is subsequently reconciled with main at
`83954f1fbffbee1df5fb25e69ab3b34bc92346e8`. That merge is clean. Dispatch's
assignment implementation and the Lean/Quint exclusivity model sources are
unchanged; the target/patch hashes still match the successful experiment.
Main brings dependency changes including Ash 3.37.3, so fresh exact-head CI
is required before accepting the integrated branch. Earlier successful runs
remain evidence only at their pinned revisions.

The minimal profile-binding patch is ready for owner review, but remains
unapplied in the committed operational module. It does not choose E2/E3 or
solve role validity, organizational scope, lifetime/provenance or full runtime
refinement. #296 remains open. No assignment migration or deployment is added.
