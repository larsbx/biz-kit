# Workflows in the view

Date: 2026-10-20. Status: **implemented**. Follows
[hierarchy and blueprints](2026-10-20-hierarchy-and-blueprints.md), which
left the hierarchy out of the web view and the feed.

A person now sees a project's workflows on its page. Running one takes a
button and a name. The tasks a run makes say which workflow and step they
came from.

## The feed

A project's view (`Feed.View`) gains the kind **workflows**:

| Kind | Key | Fields |
| --- | --- | --- |
| workflow | `roadmap/workflow`, each part URI-encoded | `roadmap_key`, `roadmap_name`, `workflow_id`, `name`, `revision_event_id`, `source` (`repository`, `commit`, `path`), `definitions` (`id`, `title`, `description`, `depends_on`, in the blueprint's order) |

- **Current revision only.** A workflow appears under the revision that now
  governs it, the only one a run may use.
- **Updates.** Applying a new revision replaces the entity, and the frame
  carries it like any other change.
- **What a definition carries.** Its Definition of Done criteria and input
  names are not part of the workflow. They are part of each task a run makes.

A task made by a run now carries **`blueprint`**:
- `revision_event_id`, `roadmap_key`, `workflow_id` and `definition_id`;
- `predecessor_ids`, the run's own tasks;
- `artifact_requirements`, the input names that readiness must keep.

The delivery contract is unchanged (`spec/change_feed.qnt`).

## The page

- **Workflows** lists each workflow:
  - its roadmap;
  - its steps in order, each with the steps it comes after;
  - its source (repository, short commit, path);
  - **Run…** for an enrolled operator device.
- **Run…** asks for a run name. A run's tasks are `<run>-<step>`. The page
  refuses before preparing anything in these cases:
  - the name is not lowercase letters, digits, `-` and `_` (up to 64);
  - any of the IDs already exists, or is longer than the ledger's 128 bytes.
- **Signing.** The device signs `TaskWorkflowInstantiatedV1` only if the
  server prepared exactly that revision, roadmap, workflow and set of task
  IDs (`isExpectedCommand`). The confirmation dialog shows the command, as
  for every step.
- **Tasks.** A task from a run says **From workflow ‹name›, step ‹step›**.
  Its next step is the existing lifecycle: Propose, then waiting for
  readiness, and so on.

## Verification

- **`ChangeFeedViewTest`:** the generated histories now apply two blueprint
  revisions and attempt runs under either. A run under the revision
  governing the workflow is admitted, and one under a superseded revision is
  refused as stale. Every view property holds with them. The coverage test
  now expects all eight kinds, and at least one task made by a run.
- **Node:**
  - workflows sort by roadmap, then name;
  - a run's task IDs are built, and refused when taken or badly named;
  - a run task's origin is named;
  - the device refuses a run whose task IDs or revision differ from what it
    asked for.
- **Chromium:**
  - the person's page lists the applied workflow with its order;
  - **Run…** named `r1` signs exactly `r1-build` and `r1-ship`;
  - the new task shows its origin within 5 s.

  With the origin label changed, the browser test fails.

## Limits

- **Administrators see no hierarchy.** The chapter's feed does not carry
  workflows; an administrator sees them on a project's page.
- **Applying is the governance tool's job.** The page shows workflows but
  does not apply blueprints; `mix coop.blueprint` does.
- **Runs are not grouped on the page.** Runs and their tasks are shown as
  tasks; the run name is only their prefix.
