# Readiness for a workflow run

Date: 2026-10-20. Status: **implemented**. Follows
[workflows in the view](2026-10-20-workflow-view.md).

A workflow run's tasks start in the inbox. An operator proposes each one,
and then each waits for governance to define its readiness: the digest of
each input, and the SOP. Until now, no path outside the tests could sign
that definition, so a run in a real deployment stopped at its first step.
An administrator now defines readiness for a whole run at once, from the
project's page.

## Decision

The blueprint already fixes each task's predecessors (the run's own tasks)
and the names of its inputs (`TaskCore.Hierarchy.keeps_blueprint/3`), so
those are filled in, never chosen. Governance supplies only digests:
- one per input, per task;
- one for the SOP the run follows. A run uses one SOP; the ledger still
  records it per task, as an exact digest.

`CoopSubstrate.RunReadiness` holds one `TaskReadinessDefinedV1` per task of
the run that is proposed or queued and has no readiness yet, as one batch
(`Commands.hold_batch/4`) for a governance key to sign. The batch is
appended at once. Each definition is admitted by the existing rules: a
declared governance key, the task's current version, a proposed or queued
task, and the blueprint's predecessors and input names kept.

| Request | Answer |
| --- | --- |
| `POST …/projects/:project_id/runs/:run_event_id/readiness` `{"governance_key_id", "sop_digest": hex, "inputs": {task_id: {name: hex}}}`, signed by a governance key of the chapter (`Governance.Read`) | 201: the definitions to sign. 409 `nothing_to_define` if no task of the run is waiting. 400 `missing_input` if an input digest is missing. |
| `POST …/runs/:run_event_id/readiness/:held_id` `{"signatures"}` | 201: the appended events |

A task made by a run now records the run (`blueprint.run_event_id`, the
instantiation event), so a run can be named in a request and grouped in the
view.

## The page

- **Under each workflow:** each of its runs shows its progress, for example
  "Run r1: 1 of 2 completed". The run's name is the `<run>` its task IDs were
  made with.
- **For an administrator:** a run with tasks waiting shows **Define readiness
  (n)…**. The dialog asks for the SOP's digest and one digest per input of
  each waiting task. It offers the digests already held in the project's
  custody to pick from, or a digest can be pasted.
- **Signing:** the browser signs only if the server prepared exactly the
  definitions it built from the view (`runReadiness`, `isExpectedBatch`).
  The confirmation shows them all, and they are signed in one go.

## Verification

- **Ledger (`TaskHierarchyTest`):**
  - nothing to define while a run's tasks are in the inbox;
  - a missing input digest is refused;
  - one batch defines both tasks, with the blueprint's predecessors, the
    input digest and the SOP;
  - once defined, there is nothing left to define;
  - an operator key cannot sign it;
  - a batch cannot be submitted under another run.
- **HTTP (`RunReadinessTest`):**
  - a governance key signs the batch with `Client.sign_batch/4`, checking
    each definition first;
  - an unsigned request gets 401;
  - a malformed digest gets 400;
  - a second request gets 409.
- **Node:** runs are grouped, named and counted; exactly the waiting tasks
  are defined; a missing digest is said.
- **Chromium:**
  - the person runs the workflow and proposes its first step, which waits
    for readiness;
  - the administrator's page shows "Run r1: 0 of 2 completed" and **Define
    readiness (1)…**;
  - the administrator picks a stored SOP digest and signs exactly the one
    definition;
  - the person's task stops waiting.

## Limits

- **One SOP per run.** A run whose steps follow different SOPs needs the
  batch split. The ledger supports that, but the page does not offer it.
- **Proposed tasks only.** Only tasks already proposed can be defined, as
  readiness requires. A run whose later steps are proposed later takes more
  than one batch.
- **No command-line path.** There is no `mix coop.readiness`. A script holding
  a governance key can call the endpoint with
  `CoopSubstrate.Governance.Client.sign_batch/4`, as the HTTP test does.
