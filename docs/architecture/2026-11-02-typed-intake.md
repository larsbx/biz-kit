# Typed intake: request types and the requester's agreement

This extends [DoD evidence and review](2026-10-11-dod-evidence-review.md). It
is the first slice of SPEC_dod_grammar v0.2 in TaskCore: a request type fixes
the shape of a task's Definition of Done, and the person who asked for the
work agrees to that exact definition before it can be queued.

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
| `TaskDoDDefinedV2` | Declared governance key; proposed task at expected version; `catalogue_ref` names a catalogue the host holds (`read_catalogue/1`), which normalizes; `criteria` equal `TaskCore.Intake.instantiate(catalogue, request_type, params)` exactly. | A current definition, as V1 (criteria digest, cleared submission/review), that also records the request type, parameters, catalogue digest and the defining key, with no agreement. |
| `TaskDoDAgreedV1` | Active scoped operator grant, matching principal and key; proposed task at expected version; current definition is typed and is the one cited; no agreement yet; the principal is the one who proposed the task; the signing key differs from the one that defined it. | The agreement, on the current definition. |
| `TaskQueuedV1` (changed) | As before, and a typed definition must be agreed. | Unchanged. |

V1 definitions are untouched: they need no agreement and queue as before.
New types are additive, and no existing canonical core changes.

## Catalogue

A catalogue is decoded data the host stores by digest:

```elixir
%{"request_types" => %{
    "feature" => %{
      "params" => ["area", "kill_rate"],
      "criteria" => [
        %{"id" => "tests", "description" => "Property tests for {area} pass"},
        %{"id" => "mutation", "description" => "Mutation kill rate for {area} is at least {kill_rate}"}
      ]}}}
```

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
of request requires, publish a new catalogue under a new digest; definitions
already made keep citing the digest they were checked against.

## Decisions

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
* **The payload carries the criteria.** Admission recomputes them from the
  catalogue. Replay folds the payload and reads no catalogue, so what was
  admitted is what replays, with no store read during the fold.
* **Fail closed.** A host without `read_catalogue/1`, or one that cannot
  produce the cited digest, refuses typed definitions
  (`intake_catalogue_unavailable`).

## Refusals

`intake_catalogue_unavailable`, `invalid_intake_catalogue`,
`unknown_request_type`, `intake_params_mismatch`, `invalid_intake_param`,
`intake_template_mismatch`; `dod_not_typed`, `dod_already_agreed`,
`dod_agreement_not_requester`, `dod_agreement_same_key`; on queueing,
`dod_not_agreed`. The existing `dod_not_defined`, `dod_revision_mismatch`,
`dod_task_not_proposed`, stale-version and grant refusals apply as before.

## Not yet

* **CoopSubstrate's host.** `CoopSubstrate.TaskHost` does not implement
  `read_catalogue/1`, so the ledger refuses `TaskDoDDefinedV2` until it
  does. That follows from the fail-closed decision above, and it needs a
  decision on where catalogues are stored and who may publish one.
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

Tests were written first and failed for the missing module:
`apps/task_core/test/intake_test.exs` has 16 tests, covering the pure catalogue and
instantiation rules and the full admitted path through a host with a
catalogue. The path runs from operator grants through a real custody
receipt, readiness and SOP acknowledgement, to queueing and starting.

Eleven hand-made mutants of the new guards each fail at least one test:
- dropping the queue gate;
- dropping each agreement refusal, including the proposed-only window;
- accepting any criteria;
- loosening each catalogue and parameter rule, including the repeated-parameter rule.

The whole TaskCore suite (120 tests) passes locally on Elixir 1.14/OTP 25,
with the app's Elixir requirement relaxed for that run. This does not
replace the project's Elixir 1.19/OTP 27 run or the CoopSubstrate and
PostgreSQL acceptance suites, which were not run.
