# Project ownership: an eligible accountable owner before work

Date: 2026-11-02. Status: **implemented**.
Follows [typed intake](2026-11-02-typed-intake.md), which introduced the
project owner who adopts the intake catalogue.

Ownership establishes accountability, grants establish authority, and
governance controls both. This strengthens TaskCore's existing invariants and
does not add a competing ownership model:

| Layer | Meaning | Authority |
| --- | --- | --- |
| Owner | Exactly one accountable human principal per project | None inherent |
| Stewards | Named operational responsibilities | None inherent; **deferred** until a rule reads them |
| Grants | Operator, reviewer and suggester grants, and delegations | Authoritative, as before |

The organizational owner is the chapter. Every project is
`{chapter, tenant, project}`, and the chapter's governance keys govern it.
`cannot_orphan_governance` already keeps a chapter from losing its last one,
so no event is added for that layer.

## Contracts

| Event | Authority and precondition | Committed result |
| --- | --- | --- |
| `TaskPrincipalKindDeclaredV1` | Declared governance key; nonblank `principal_id`; `kind` is `human` or `agent`, and not the kind already declared. Chapter-scoped: no tenant or project. | The principal's kind in the chapter. |
| `TaskPrincipalKindWithdrawnV1` | Declared governance key; the principal has a declared kind. Chapter-scoped. | The principal has no kind. |
| `TaskProjectOwnerAssignedV1` (changed) | Declared governance key; nonblank `principal_id` that is not the current owner. The transition rule below refuses an ineligible owner. | The project's owner, replacing any previous one. |
| `TaskCreatedV1`, `TaskWorkflowInstantiatedV1`, `TaskBaselineRecordedV1` (changed) | As before, and the project has an owner (`project_has_no_owner`) who is eligible (`project_owner_ineligible`). | Unchanged. |
| **Every task event** (changed) | As before, and the state after it has no project with an ineligible owner that did not have one before (`project_owner_ineligible`). In a batch, this is checked once, after the whole batch. | Unchanged. |

**Eligible owner.** Governance has declared the principal `human` in the
chapter, and the principal holds an active operator grant in the project. An
undeclared principal never qualifies.

## The invariant, as obligations

These are the acceptance obligations, method `conformance`. Each is
discharged by an executable check, not by review. `TaskCore.Projects.violations/1`
is the invariant itself, and admission uses the same function
(`TaskCore.Admission.check_transition/2`).

| ID | Obligation | Discharged by (`apps/task_core/test`) |
| --- | --- | --- |
| OWN-1 | No admitted sequence of events reaches a state with an ineligible owner. | `ownership_test.exs`: "no admitted sequence reaches an ineligible owner, or work without one", 150 seeded random walks of 40 steps over kinds, grants, revocations, offboardings, assignments, task creation and two-event batches. The test asserts the walks actually admit and refuse each case, so it cannot pass vacuously. |
| OWN-2 | No task is created, workflow run or baseline recorded without an eligible owner. | Same random walks; "no task is created or baseline recorded without an eligible owner"; `lesson_workflow_test.exs`: "a run is new work". |
| OWN-3 | Agents, and undeclared principals, are never eligible owners. | "the owner must be a declared human holding an active operator grant"; "a successor must be eligible at the end of the batch". |
| OWN-4 | Every route to losing eligibility is refused while the principal owns a project: revoking the last operator grant, the holder revoking their own last device, offboarding, re-declaring them an agent, withdrawing their kind. | The "no orphaned project" tests, one per route, plus "the guard follows the owner into every project they own". |
| OWN-5 | A batch that also assigns an eligible successor is admitted, in either order. | "offboarding and reassignment succeed together, in either order"; "simultaneous revocation and reassignment, in either order". |
| OWN-6 | Only governance assigns or transfers ownership. | "only governance assigns or transfers ownership"; "each event's own rules still apply inside a batch". |
| OWN-7 | Ownership confers no authority. Grants keep their meaning. | "ownership confers no authority: grants alone do"; "a project's owner does not license work in another project". |
| OWN-8 | Historical ownerless projects stay readable and are backfilled without rewriting history. | "an ownerless legacy project is backfilled without rewriting its history". |
| OWN-9 | Every ownership change is attributable. | "every assignment is a signed, attributable governance event". |

Eighteen hand-made mutants of these rules each fail at least one test. They
cover weakening each eligibility condition, each of the three kinds of work,
the batch deferral in both directions, the transition check and the kind
rules. The Proof Bank core (`apps/proof_bank_core`) is an inert specification
compiler with no registry of platform invariants, so these obligations are
recorded here, against their checks, rather than registered there.

## Decisions

* **One invariant, not one check per route.** Owner eligibility is checked on
  the state after an event, not by listing the events that can break it. Any
  route that ends an owner's eligibility, including future ones, is refused
  the same way, and new event types need no new guard.
* **No new violations, rather than none at all.** A transition is refused if
  it adds a project with an ineligible owner. From an admitted ledger, which
  has none, that is the same as none at all. A state that somehow holds one,
  such as a replayed history, still admits unrelated events, and governance
  can repair it by reassigning. Such a project takes no new work.
* **Batches are validated together.** `TaskCore.Admission.check_batch/2`, and
  the ledger's `Log.append/2` and `Commands` preview, check each event's own
  rules at its position, then owner eligibility once, on the final state. A
  batch may therefore offboard or revoke an owner and assign a successor in
  either order. The successor must be eligible by the end of the batch. A
  ledger rejection for the batch as a whole is reported against its last
  event (`{:reject, last_index, :project_owner_ineligible}`).
* **Strict unless a host opts in.** Admitting a single event checks the
  invariant immediately. Only a host that sets `defer_transition: true` for
  each event, and then calls `check_transition/2` on the whole batch, defers
  it. A host that does neither stays strict.
* **Authoritative state only.** Every check reads the gate's state, which is
  the fold of committed and in-batch events. Nothing reads an identity
  provider, a session or a cached snapshot.
* **The kind is an attestation.** `human` means governance attests that the
  principal is a person. The ledger enforces that only governance confers it,
  and cannot establish personhood itself. Disabling an identity in the
  identity provider (`BizKit.Identity`) does not by itself change the ledger.
  Governance withdraws the principal's kind or offboards them, and the
  invariant then applies.
* **"New work" is creation.** Task creation, workflow runs and baselines need
  an eligible owner. Moves on tasks that already exist (proposing, queueing,
  completing, cancelling) do not, so in-flight work in a legacy project can
  finish or be cancelled while governance backfills its owner.
* **Bootstrap needs no owner.** Declaring a kind, granting an operator,
  assigning an owner and applying a blueprint are governance acts, not work.
  None of them requires an existing owner.
* **Kinds are chapter-wide.** A principal is one person or one agent across
  the chapter's projects. Its events use the chapter-scoped stream
  `<chapter>/task_principals` and name no tenant or project.

## Migration

Main has no project owners: `TaskProjectOwnerAssignedV1` ships in the same
change. Existing projects are ownerless. They stay readable and keep their
in-flight work, and they accept no new tasks, runs or baselines until
governance backfills them with one batch per project:

1. `TaskPrincipalKindDeclaredV1` for the owner, once per chapter;
2. a `TaskOperatorGrantedV1` for them in the project, if they hold none;
3. `TaskProjectOwnerAssignedV1`.

Backfill adds facts and rewrites no history: replay of the old events
yields the same tasks.

The server-side backfill implementation in the stacked successor branch is
`CoopSubstrate.ProjectOwnership`:

* `ownerless(chapter)` lists only existing projects with historical tasks or
  grants and no owner, without mutating the ledger.
* `prepare_backfill({chapter, tenant, project}, principal, governance_key_id, device)`
  prepares the missing human-kind declaration (unless already declared),
  an operator-device grant (unless already held), and an owner assignment.
  The key and public key must be supplied by the administrator/device; no
  device is created or silently inferred. Agent principals are refused.
* `backfill(scope, principal, held_id, signatures)` attaches a governance
  signature to every command. Its admission guard recomputes the exact
  expected batch against current state, so an intervening assignment or
  grant cannot be overwritten by a stale held request.

The signed HTTP interface now exposes
`GET /api/v1/chapters/:chapter_id/ownerless_projects` and
`POST /api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/ownership/backfill/:principal_id`
(with a `/:held_id` submission route). Governance must authorize the
read and preparation, and each prepared command's canonical core is signed
before commit. The chapter offboarding prepare API also accepts a
duplicate-free `successors` array with tenant, project and principal IDs.
A graphical owner/successor selector remains outstanding in #265.

For headless administration, `mix coop.owner.backfill CHAPTER TENANT PROJECT PRINCIPAL`
uses the existing governance seed in `HARNESS_KEYS_DIR` to sign a prepared
backfill batch over HTTP. It checks exact canonical event types, chapter,
tenant, project, principal and any supplied operator device before signing.
Use `--device-key-id KEY --device-pubkey BASE64URL` only if the successor
has no existing active operator grant. The seed never leaves the client.



## Not yet

* **Administration views.** The server-side chapter offboarding interface
  now supports `Offboarding.prepare_chapter/4`, with a map from
  `{tenant_id, project_id}` to eligible successor principals. It requires
  one successor for *every* project still owned by the departing principal,
  produces one governance-signed atomic batch, and rechecks selections
  against current owner/holdings state at admission. The administration
  page/client does not yet expose successor selection or legacy backfill;
  that remains tracked in issue #265.
* **Stewards and an explicit project lifecycle** (draft, active, archived) are
  deferred until a rule needs them.
* **Model check.** The Quint models (`apps/task_core/spec`) do not include
  ownership.
* **Owner-signed acts** beyond catalogue adoption: an owner has no further
  powers, by design.

## Validation

TaskCore: 148 tests, including the 23 ownership tests and the updated intake,
lesson and salvage fixtures. They pass locally on Elixir 1.14/OTP 25 with the
app's Elixir requirement relaxed, and in CI on Elixir 1.19/OTP 27. CoopSubstrate
and SpruceGoose could not be compiled in the authoring sandbox (Hex
unreachable); their suites and the release smoke run in the Consolidation
workflow, and SchoolOps in its own.
