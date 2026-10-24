# SchoolOps — the school domain within biz-kit

SchoolOps is a **domain app**, just as Dispatch is. Its administration, task
management, review, authorization and event history should use **the same
biz-kit platform services** as the other domains. Only the school-specific
vocabulary, records, rules and interfaces belong here.

## Delivered domain features

- `SchoolOps.Catalog`: stable-ID lookup for the first Grade 2 course, unit,
  six lessons, two assessments and seven reviewed optional resources. It reads
  the bundled public curriculum content and does not infer learner mastery.
- `SchoolOps.Workflows`: the first **staff** readiness workflow for the
  place-value unit. It proposes five linked tasks: scope, resource suitability,
  lesson preparation, assessment review and a weekly teaching plan.
  It emits TaskCore schema-2 data and delegates validation and planning to
  `TaskCore.Blueprint` / `TaskCore.Workflow` with
  `TaskCore.TaskLifecycle`. SchoolOps has no parallel task state machine.
- `SchoolOps.read/1`: safe read-only access to public authored content.
  Source materials remain pinned from
  [larsbx/school-ops](https://github.com/larsbx/school-ops) at
  `ccacc596d63a7b04d33d62bc77636fd93de9f995` (original Git blob IDs in
  [source-manifest.tsv](source-manifest.tsv)).

Example from inside the umbrella:

```elixir
{:ok, unit} = SchoolOps.Catalog.fetch("U-MATH-001-01")
{:ok, blueprint} = SchoolOps.Workflows.validate()

ids = %{
  "scope_review" => "scope-42",
  "resource_review" => "resources-42",
  "lesson_review" => "lessons-42",
  "assessment_review" => "assessment-42",
  "weekly_plan" => "weekly-42"
}

{:ok, proposed_tasks} = SchoolOps.Workflows.plan(ids)
```

These are **proposals**, not persisted or authorized tasks. Using them in the
shared platform still requires source attestation, scoped principal/grant
checks, atomic task-ID allocation, the normal signed admission command and
evidence custody/review. `SchoolOps` does not bypass those services.

## Shared platform versus school-specific features

| Shared from biz-kit | Added by SchoolOps |
| --- | --- |
| `task_core` DAG, lifecycle, Definition of Done and reviews | Course → unit → lesson planning and prerequisites |
| `coop_substrate` authorized ledger admission and provenance | Lesson preparation, material/assessment readiness criteria |
| `biz_kit_identity` principal, authentication and grants | Teacher/reviewer school roles **mapped to** scoped grants (future integration) |
| Task timing, delegation, workflow runs and change feed | Teaching calendar, resource suitability, class and learner workflows (future reviewed slices) |

Learner identity, scores, accommodations and class-specific assignment links
must never enter this public source package, proposed task descriptions or logs.
Student-facing operations require an explicitly scoped private storage and
access-control design; they will still reuse common platform admission, rather
than establish another source of business truth. Material `ready`, completed
staff tasks and learner mastery are separate facts.

The original `school-ops` repository can continue as a **versioned source
of educational materials**. There is no school-app *migration*, repo archival,
editorial cutover or task-system replacement prerequisite to developing
domain features in this app. When materials change upstream, review and pin a
new content revision here, preserving all stable identifiers and source rights.

See [domain architecture](../../docs/architecture/2026-10-23-school-ops.md)
and [the source curriculum](priv/content/README.md). Run `mix test` from
this app to exercise catalog and shared-workflow contracts.
