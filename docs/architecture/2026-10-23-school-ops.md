# SchoolOps: a peer domain in biz-kit

Date: 2026-10-24.
Status: **domain feature slice; platform admission remains shared**.
This supersedes this document's October 23 framing as an editorial
migration/cutover exercise.

## Decision

School operations follows the same **domain app pattern** as Dispatch and
the other parts of biz-kit: shared task management, identity, authorizations,
event history, projections, evidence custody, scheduling and interface
infrastructure, with additional school-specific domain features.

`apps/school_ops` is **not a migration** from `larsbx/school-ops`. The
original repo remains the authoritative curriculum-authoring source.
Its pinned copies live under `apps/school_ops/priv/content/`; source commit
`ccacc596d63a7b04d33d62bc77636fd93de9f995` and per-file Git blobs
are retained for reproducible content updates. There is no required editor,
issue, or repository cutover. Domain application code develops here.

## Shared foundations (do not reimplement)

| Platform concern | Existing owner | SchoolOps usage |
| --- | --- | --- |
| Task definitions, dependencies and lifecycles | `task_core` | Validated teacher/staff workflow definitions, planned task instances |
| Task admission, evidence, review, provenance | `coop_substrate` + `task_core` | Authorized steps, assessment evidence rules, independently reviewed completion |
| Identity, scoped grants, revocation | `biz_kit_identity` and common ledger | Teacher, reviewer, administrator, guardian and learner roles **only after explicit scoped mapping** |
| Task timing, delegation and change feed | Platform task/orchestration modules | Teaching-week preparation, staff follow-ups and notifications |
| Configuration, releases, deployment | Existing umbrella | `:school_ops` deployed through ordinary biz-kit releases |

The ledger is the platform's admission authority, not an instructional-grade
storage subsystem. Private learner records need domain-specific protections,
but must not create an independent authority for shared task transitions.
No teacher review grants can be inferred from course names or a login.

## Selected storage contract for the hosted backend

The [October 30 storage ADR](2026-10-30-postgres-event-log-redis-consolidation.md)
and [school-ops decision 0008](https://github.com/larsbx/school-ops/blob/main/docs/decisions/0008-platform-storage-and-operations.md)
supplement this domain slice. Curriculum, assessment text, editorial readiness
and source rights remain under the independent content repository; immutable
imports do not transfer authoring authority or require its authors to deploy
PostgreSQL, Redis, TigerBeetle or Hawala.

| Concern | SchoolOps backend obligation |
| --- | --- |
| Commands | Use the shared signed admission path and current scoped grants/revocation; no direct SQL appender or competing task writer |
| PostgreSQL | Retain admitted business history, governed import manifests, operational intent, permanent source/body bindings and effect receipts; projections retain their verified source watermark |
| Replay | Consume a verified complete prefix with bounded reads; atomically persist the complete bundle, receipt and cursor where co-located, otherwise use source-bound idempotent admission and prove append-before-cursor recovery; stop on unknown types or gaps |
| Redis | Use the shared worker for retained scheduling, retry, cancellation, reclaim and notifications; rebuild work/views from durable intent, receipts and pinned source after Redis loss |
| Optional finance | Use the authenticated Hawala boundary only for separately authorized future financial workflows; TigerBeetle acceptance/balances do not establish teaching or learner outcomes |

Original IDs and immutable body binding survive retries. Recheck authorization
at execution, retain durable effect evidence, and ACK only after durable owner
completion. A scheduler lease, cached role or task preview cannot authorize an
effect. Preserve tenant/scope and source-revision separation in derived views.

This is a selected target specification. The existing EventStore backend stays
active until P1–P8 pass against its actual replacement; historical proof and
synthetic acceptance do not certify new adapters. Backend implementation PRs
must retain exact-revision Lean/Quint refinement, concurrency, crash/replay,
Redis-loss and scoped authorization evidence, then fence old writers at verified
cutover. Optional finance retains Hawala S-A1–S-A7 and existing release gates.
This amendment activates no school commands, learner storage or financial path.

## First school-specific slice

1. `SchoolOps.Catalog` indexes the existing Grade 2 mathematics course,
   place-value unit, lesson and assessment IDs, plus optional resources.
   This is a read-only authoring catalog; no student or school records.
2. `SchoolOps.Workflows` produces a TaskCore schema-2 blueprint for
   Grade 2 place-value unit staff preparation. It uses the same DAG,
   Definition-of-Done and versioned lifecycle as other biz-kit domains.
   Scope review precedes lessons/resources; assessment review depends on
   lesson review; weekly planning depends on resources and assessment.
3. `SchoolOps.Workflows.plan/1` calls `TaskCore.Workflow.plan/5` to
   resolve a run's task IDs and dependencies. It never appends business
   events or claims material readiness/teaching outcomes. Production
   application must verify signed blueprint provenance, allow appropriate
   scoped grants, allocate unique IDs and admit through the normal ledger.
4. Existing course/lesson `draft` status stays `draft` until editorial
   readiness review. A completed *staff workflow* is not evidence that a
   learner has learned anything. Trivium and Quadrivium pedagogy, including
   the explicit exclusion of music, remains in force.

## Domain roadmap

- **Course operations:** course catalog, unit/lesson prerequisites, resource
  review, class/teacher planning, timetables and teaching-material readiness.
- **Classroom execution:** preparation and assignment workflows through
  shared TaskCore tasks, with reviewable teaching evidence and due dates.
- **Assessment:** forms chosen from actually taught scope; outcomes, teacher
  keys and evidence criteria, distinct from workflow or resource readiness.
- **Learner services:** protected enrollment, attendance, individual progress,
  accommodations and guardian consent only after privacy, authorization,
  retention and tenant separation have been specified and tested.
- **Interfaces:** school section of the biz-kit application with views over
  shared tasks and school-specific records, not a standalone school portal.

## Safety and acceptance gates

Never publish student names, grades, accommodations, attendance, teacher
class rosters or class-specific assignment links as Git curriculum content,
blueprint descriptions or public API output. No new school event writer,
task table, ledger or independently trusted scheduler. Preserve upstream
source rights: optional third-party educational resources are references,
not redistributable assets. Validate content IDs, DAG, reviewed DoD criteria
and actual scoped admission before enabling task mutations.

This change adds domain logic and reusable **proposed** workflows; it does not
yet wire a school UI or authorized school commands to live ledger endpoints.
That is a separate reviewed integration slice, not a migration.
