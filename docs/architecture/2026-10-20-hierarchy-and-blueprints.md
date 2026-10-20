# Hierarchy and blueprints

Date: 2026-10-20. Status: **implemented**. Builds on
[the task core](2026-10-20-task-core.md).

A project's roadmaps and workflows are a reviewed document kept in git: a
**blueprint**. Governance applies one revision at a time from a pinned
source. An operator then runs a workflow, which creates every task of the
workflow at once. For school operations, a curriculum is the blueprint:
- a term is a roadmap;
- a unit is a workflow;
- a lesson is a task definition, with its assessment as the Definition of
  Done.

SpruceGoose already had this, on Ash and PostgreSQL
(`SpruceGoose.Workflows.{Project, Roadmap, Workflow, BlueprintRevision}`,
`Blueprints.Applier`, `Blueprints.ForgejoVerifier`). The rules now live in
`task_core`, and the signed ledger is their first host.

## Reviewing SpruceGoose's design

Two differences stay as they were, on the ledger's side, as decided for the
task core:
- predecessors are checked before `ready`;
- the SOP is an exact digest per task.

Every other difference was reviewed. The four marked *(asked)* were your
decisions; the rest follow from them or from the existing ledger.

| Aspect | SpruceGoose | Ledger before | Now | Why |
| --- | --- | --- | --- | --- |
| Definition of Done in a definition *(asked)* | One string | Criteria `[{id, description}]` | Criteria | Evidence and review are per criterion, and an assessment maps onto criteria. |
| Where an instance's Definition of Done and dependencies come from *(asked)* | Copied from the exact revision when instantiated | Governance defines them per task | From the revision. Governance may still redefine the Definition of Done while the task is proposed. Readiness must keep the blueprint's predecessors and input names. | The blueprint is the reviewed, governance-signed source. Only digests and the SOP stay per task. |
| How roadmaps and workflows change *(asked)* | Only by applying a blueprint revision ("constitutive lockdown") | No hierarchy | Only by `TaskBlueprintAppliedV1` | One reviewed path, and no ad-hoc edits that drift from git. |
| Source verification *(asked)* | The server walks the Forgejo commit → tree → blob chain on every apply and instantiation | — | The governance tool walks the same chain (`ForgejoVerifier`, unchanged). The server stores the exact bytes in custody, and admission rereads them and requires the signed blueprint to be their normal form. | The append gate never calls the network, replay never reads files, and the bytes stay checkable later. |
| Instantiating | One task at a time; dependencies linked separately | — | A **workflow run** names a new task for every definition, and the run's tasks are each other's predecessors | One task at a time cannot resolve `depends_on`. A run can. |
| Which revision a run uses | Any revision of the project | — | Only the revision now governing the workflow (`stale_blueprint_revision` otherwise) | A superseded definition should not start new work. Existing tasks keep what they were made from. |
| Applying | Creates or renames by key, never deletes; once per `(project, repository, commit, path)` | — | The same | Removal would orphan tasks. Once per source keeps provenance unambiguous. |
| Workflow definition nesting | `workflow.definition = {schema_version, tasks}` | — | `workflow.tasks`, with one `schema_version` (2) per document | One version per document is simpler, and the formats cannot be confused. |
| Runner `kind`, `input` | Oban / TaskFlow / OpenClaw, and a free map | — | Not in the schema | They describe an executor, not the work. A host that executes can add its own document. |
| Identifiers | Lowercase `[a-z0-9][a-z0-9_-]`, up to 128 bytes | Scope segments `[A-Za-z0-9][A-Za-z0-9_.-]` | SpruceGoose's | Its form is a subset of a ledger segment, and case-insensitive storage cannot collide. |
| Commit and tree IDs | 40 hex characters (SHA-1) | — | The same | The Forgejo verifier recomputes SHA-1 object IDs; SHA-256 repositories need a verifier that does the same for their format first. |
| Bounds | Title 300 bytes, Definition of Done 2,000, 50 input names | Ledger: 32 predecessors, 32 inputs, 1–32 criteria | Title 300, description 2,000, the ledger's 32/32/1–32; 32 roadmaps, 32 workflows per roadmap, 64 tasks per workflow; 1 MiB per document | Readiness must be able to keep what the blueprint fixes. |
| TODO checklists, boards, saved filters | Present | — | Not adopted | They are views and personal organization, not reviewed structure. |

## The document

`TaskCore.Blueprint.normalize/1` takes a decoded document. The host decodes
it; on the ledger, it is YAML. The result is the document's normal form, the
term that gets signed. A complete example is in the module documentation.

```yaml
schema_version: 2
project: {key: maths, name: Year 7 maths}   # key = the ledger project_id
roadmaps:
  - key: autumn
    name: Autumn term
    workflows:
      - id: fractions
        name: Fractions
        tasks:
          - id: intro
            title: Introducing fractions
            description: Halves, thirds and quarters        # optional
            definition_of_done: [{id: worksheet, description: The worksheet, answered}]
            artifact_requirements: [worksheet]             # optional
          - id: adding
            title: Adding fractions
            definition_of_done: [{id: quiz, description: The quiz, passed}]
            depends_on: [intro]                            # optional
```

Normalization:
- refuses unknown or missing keys;
- requires every ID to be unique in its scope;
- requires each workflow's dependencies to be a DAG (`TaskCore.Dag`);
- keeps the author's order;
- fills `depends_on` and `artifact_requirements` with `[]` when absent.

## Events (`TaskCore.Hierarchy`)

| Event | Signer | Admission | Fold |
| --- | --- | --- | --- |
| `TaskBlueprintAppliedV1` `{repository, commit, tree, path, manifest_digest, blueprint}` | governance | See below | The revision is recorded by its event ID. Each roadmap and workflow is created or renamed by key, and every workflow it names is now governed by this revision. |
| `TaskWorkflowInstantiatedV1` `{revision_event_id, roadmap_key, workflow_id, task_ids}` + actor | operator | An active grant and lifecycle version 1. The workflow is governed by exactly this revision. `task_ids` maps every definition to a distinct, safe, unused task ID. | One task per definition, as described below. |

`TaskBlueprintAppliedV1` is admitted when:
- it is signed by a declared governance key;
- the source fields are well formed;
- this source has not already been applied to this project;
- the host holds bytes under `manifest_digest` (`Host.read_blueprint/1`);
- the signed `blueprint` is their normal form;
- `project.key` is the event's `project_id`.

Each task a run creates:
- is in `inbox`, with the definition's title and description;
- has its Definition of Done already defined (criteria and the host's hash);
- records `blueprint`: the revision, roadmap, workflow, definition, its
  predecessors (the run's tasks for `depends_on`) and its input names.

Readiness for such a task (`TaskReadinessDefinedV1`) must name exactly
those predecessors and input names; otherwise `blueprint_readiness_mismatch`.
Governance binds the input digests and the SOP as before. Every other step
is the existing lifecycle.

Both events are part of `TaskCore.Admission`. A retried run returns its
first acknowledgement (`hierarchy_commands`, `Tasks.duplicate/2`).

### The host port

`TaskCore.Host.read_blueprint/1` is an optional callback. It returns the
blueprint stored under a digest, decoded. A host without it refuses
`TaskBlueprintAppliedV1` with `blueprints_unsupported`. On the ledger,
`CoopSubstrate.TaskHost` reads from the custody store, up to the custody
limit, and decodes YAML into strings only (no atoms). Replay never reads:
the event carries the normal form.

## On biz-kit

**Applying a blueprint (governance).**

```
mix coop.blueprint <chapter>/<tenant>/<project> <repository> <commit> <path> [--server URL] [--yes]
```

The tool:
1. reads the blueprint through `SpruceGoose.Blueprints.ForgejoVerifier`,
   checking each object against the identity its parent declares;
2. shows the roadmaps and workflows;
3. sends the exact bytes and the source to
   `POST …/projects/:project_id/blueprints`, signed by the governance key
   (`Governance.Read`);
4. signs the held event only if it applies exactly those bytes from exactly
   that source to exactly the chapter, tenant and project it was given
   (`CoopSubstrate.Blueprints.expected?/4`).

The server stores the bytes, normalizes them and holds the event.
`POST …/blueprints/:held_id` submits the signature.

**Running a workflow (operator).** The existing `POST …/commands` takes
`{"action": "instantiate", "revision_event_id", "roadmap_key",
"workflow_id", "task_ids", "key_id"}`. It is prepared by
`TaskCore.Steps.command/4` and signed on the person's device, like every
other step.

## Verification

- **`task_core`:**
  - **`BlueprintTest`:** normalization and defaults, every refusal with its
    message, and the size bounds.
  - **`LessonWorkflowTest`, a curriculum host in memory:**
    - applying builds the hierarchy;
    - a run creates the lessons with their criteria, predecessors and inputs;
    - readiness must keep them;
    - malformed runs are refused;
    - a second revision takes over and runs of the first are refused;
    - wrong signer, tampered blueprint, unknown bytes, bad source, another
      project, and a second apply are all refused.

    With the readiness and revision guards disabled, two of these tests fail.
- **Ledger, `TaskHierarchyTest`:**
  - YAML bytes in custody, signed events through `Log`, and replay equal to
    the gate;
  - refusals for bytes not held, YAML that does not parse, and a second
    apply;
  - a run prepared, signed and submitted from a device (`Commands`);
  - a retried run.
- **SpruceGoose, `BlueprintTest`:**
  - `mix coop.blueprint` against a stubbed forge and the live endpoint;
  - once per source, and another project's blueprint refused;
  - an unsigned request gets 401;
  - the tool will not sign bytes other than those it read.

## Limits

- **Not shown in the web view or the feed.** The tasks a run creates appear
  in the project's feed like any other task.
- **No Quint model yet.** `task_lifecycle.qnt` still models a Definition of
  Done defined only while a task is proposed; a run's tasks start with one.
  Queuing requires a Definition of Done either way.
- **SpruceGoose's own hierarchy is unchanged.** Its Ash resources, its
  schema-1 blueprints and its CLI remain as the consolidation plan leaves
  them. Only the Forgejo verifier is shared.
- **Removing a roadmap or workflow is not modelled.** A revision that omits
  one leaves it in place, as in SpruceGoose.
