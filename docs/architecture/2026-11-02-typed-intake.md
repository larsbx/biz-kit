# Typed intake: request types and the requester's agreement

This extends [DoD evidence and review](2026-10-11-dod-evidence-review.md). It
is the first slice of SPEC_dod_grammar v0.2 in TaskCore: a request type fixes
the shape of a task's Definition of Done, and the person who asked for the
work agrees to that exact definition before it can be queued. A project has
an owner, and the owner adopts the catalogue of request types the project
accepts.

It closes two gaps in the V1 definition:

* governance alone authors a definition, so nothing records that the
  requester agreed to it (SPEC C2, dual authorship);
* criteria are free text, so two tasks of the same kind can be done to
  different standards, and a definition can drift silently (SPEC C1/J2,
  fixed signature).

It does **not** make criteria machine-checkable. Completion is still the
operator's `TaskCompletedV1`, citing an independent reviewer's acceptance.
Binding criteria to oracles and verdicts (SPEC C3–C5) is a later slice.

## Contracts

| Event | Authority and precondition | Committed result |
| --- | --- | --- |
| `TaskProjectOwnerAssignedV1` | Declared governance key; nonblank `principal_id` that is not already the project's owner. | The project's owner. A later assignment replaces it; there is no removal. |
| `TaskIntakeCatalogueAdoptedV1` | The project has an owner; signed by that owner with an active scoped operator grant (matching principal and key); the host holds YAML under `catalogue_digest` (`read_catalogue/1`) whose decoded normal form equals the signed `catalogue`; not the catalogue already adopted. | The project's current catalogue: digest and normal form. |
| `TaskDoDDefinedV2` | Declared governance key; proposed task at expected version; `catalogue_ref` is the digest of the catalogue the task's project has adopted; `criteria` equal `TaskCore.Intake.instantiate(catalogue, request_type, params)` exactly. | A current definition, as V1 (criteria digest, cleared submission/review), that also records the request type, parameters, catalogue digest and the defining key, with no agreement. |
| `TaskDoDAgreedV1` | Active scoped operator grant, matching principal and key; proposed task at expected version; current definition is typed and is the one cited; no agreement yet; the principal is the one who proposed the task; the signing key differs from the one that defined it. | The agreement, on the current definition. |
| `TaskQueuedV1` (changed) | As before, and a typed definition must be agreed. | Unchanged. |

V1 definitions are untouched: they need no agreement and queue as before.
New types are additive, and no existing canonical core changes.

## Catalogue

A catalogue is a YAML document in the custody store, at most the custody
limit, like a blueprint:

```yaml
request_types:
  feature:
    params: [area, kill_rate]
    criteria:
      - id: tests
        description: "Property tests for {area} pass"
      - id: mutation
        description: "Mutation kill rate for {area} is at least {kill_rate}"
  research-note:
    params: [topic]
    criteria:
      - id: grounded
        description: "Every claim about {topic} cites a source"
```

The host decodes it (`CoopSubstrate.TaskHost.read_catalogue/1`), and
`TaskCore.Intake.normalize_catalogue/1` validates the decoded data. Quote
descriptions that contain `{`, since YAML otherwise reads a leading brace as
a mapping.

* Request type names use the bounded segment convention. A catalogue has at
  most 64 types, and a type at most 16 parameters.
* A type's criteria obey the V1 criteria rules (1–32 unique IDs, bounded
  descriptions).
* A description names a parameter as `{name}`. The holes of a type's
  descriptions are exactly its parameters: an undeclared hole, an unused
  parameter or a repeated parameter makes the catalogue invalid. An unused
  parameter would let two definitions differ in what they record but not in
  what they require.
* Instantiation needs exactly the declared parameters, each a nonblank
  UTF-8 string of at most 256 bytes. Each value is substituted once and is
  never read as a further hole. The result must still be valid V1 criteria.

Governance therefore chooses values, never structure. To change what a kind
of request requires, the owner adopts a new revision. Definitions already
made keep the digest they were checked against, and new ones must cite the
current revision.

## Decisions

* **Projects have owners.** Request types are adopted per project, by its
  owner, never by uploading: a catalogue in the store that no owner adopted
  admits nothing. Without this, whoever can define a Definition of Done could
  also write the template it is checked against, and the fixed signature would
  hold only in name. Governance assigns the owner. Once a project has an owner
  it always has one: an owner is replaced, never removed.
* **The owner signs as an operator.** Ownership is a fact about a principal,
  not a new role or key class. The owner adopts with their own operator grant
  in the project. Governance assigning the owner and the owner adopting are
  separate signed acts, which matches SPEC C2's two-party discipline at the
  level of request types.
* **The requester is the proposer.** It is the principal of the task's one
  `TaskProposedV1`, since a task is proposed once. A creator who is an agent
  or a delegate does not agree on someone's behalf; the operator who put
  the task forward does.
* **Two keys, not two principals.** In a one-person organization the same
  person holds governance and an operator device. The agreement must come
  from a key other than the defining one, which is the strongest
  separation a single-person chapter can have. Keeping that key on a
  separate device is what gives it force (SPEC PLAN R1).
* **Agreement binds one definition.** It cites the current definition event.
  A redefinition voids it, and an agreement prepared for the old definition is
  refused (`dod_revision_mismatch`). There is no waiver, and no way to carry an
  agreement across definitions.
* **The window is `proposed`.** Like the definition itself, agreement is
  closed once the task is queued. Evidence and review stay open while the work
  is under way.
* **The store is read once, on adoption.** Adoption reads the YAML and signs
  its normal form. A typed definition is checked against the adopted
  catalogue in the fold and reads no store. Replay folds signed payloads only,
  so what was admitted is what replays.
* **Fail closed.** A host without `read_catalogue/1`, or one that cannot
  produce the digest, admits no adoption (`intake_catalogue_unavailable`). A
  project without an adopted catalogue admits no typed definition
  (`intake_catalogue_not_adopted`).

## Refusals

`project_owner_unchanged`, `project_has_no_owner`, `not_project_owner`,
`intake_catalogue_unavailable`, `invalid_intake_catalogue`,
`intake_catalogue_mismatch`, `intake_catalogue_already_adopted`;
`intake_catalogue_not_adopted`, `unknown_request_type`, `intake_params_mismatch`, `invalid_intake_param`,
`intake_template_mismatch`; `dod_not_typed`, `dod_already_agreed`,
`dod_agreement_not_requester`, `dod_agreement_same_key`; on queueing,
`dod_not_agreed`. The existing `dod_not_defined`, `dod_revision_mismatch`,
`dod_task_not_proposed`, stale-version and grant refusals apply as before.

## Not yet

* **CoopSubstrate acceptance.** `CoopSubstrate.TaskHost.read_catalogue/1`
  and retry deduplication of the project events (`Tasks.duplicate/2`) are
  written but not run. There is no CoopSubstrate preparation helper yet that
  stores catalogue YAML and holds an adoption for signing, as
  `CoopSubstrate.Blueprints.prepare/4` does for blueprints.
* **Ownership elsewhere.** Only typed intake requires an owner. Untyped
  definitions, task creation and blueprints do not consult it. Offboarding
  (`TaskPrincipalOffboardedV1`) ends the owner's grants but not their
  ownership: governance reassigns the project.
* **Workflow runs.** Tasks a workflow instantiates are proposed like any
  other, so their proposer must agree to each typed definition. SPEC's
  refinement rule (children inheriting the root's agreement) is not
  implemented.
* **Stance and rung score.** `(σ, ρ)` indexing, the S score and rung admission
  (SPEC J0/J4) are not modeled. A request type is `ρ` alone.
* **Oracle binding.** Criteria name no oracle, and nothing checks
  non-vacuity (SPEC J3) or discharges by verdict (SPEC C5).
* **Model check.** The Quint models (`apps/task_core/spec`) do not yet include
  the agreement precondition on queueing.

## Validation

Tests were written first and failed before each module existed:
`apps/task_core/test/intake_test.exs` has 20 tests. They cover:
- the pure catalogue and instantiation rules;
- owner assignment and catalogue adoption, including an impostor signing in
  the owner's name and a revoked owner grant;
- a stored but unadopted catalogue being refused, including one smuggling in
  an extra request type;
- the full admitted path through a host with catalogues, from operator grants
  and owner adoption through a real custody receipt, readiness and SOP
  acknowledgement, to queueing and starting.

Twenty-one hand-made mutants of the new guards each fail at least one test:
- dropping the queue gate;
- dropping each agreement refusal, including the proposed-only window;
- accepting any criteria;
- loosening each catalogue and parameter rule, including the repeated-parameter rule;
- dropping each ownership and adoption check;
- accepting a definition that cites any catalogue.

The whole TaskCore suite (124 tests) passes locally on Elixir 1.14/OTP 25,
with the app's Elixir requirement relaxed for that run. This does not
replace the project's Elixir 1.19/OTP 27 run or the CoopSubstrate and
PostgreSQL acceptance suites, which were not run.
