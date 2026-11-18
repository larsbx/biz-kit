# Configurable operations MVP

## Decision and scope

The operations application is reusable across organizations and households.
Names, categories, project mappings, display timezone, request catalogues and
workflow templates are configuration or existing governed definitions. No
particular business, family structure, location, industry, or role assignment
is built into the product.

The initial implementation extends the `task_host` selected and merged in
PR #356. It does not create a new umbrella application, user registry, task
database, financial ledger, or business writer.

The complete product direction remains capture, responsibility, scheduling,
execution, recorded results and exception review. This change delivers **FO-01**,
the first usable read and navigation increment. Subsequent increments below
remain explicit work rather than simulated controls.

## Delivered in FO-01

- `/operations`: responsive Today, Upcoming, All work, Review, Unscheduled,
  Closed and Workflows views.
- Configurable application title, workspace names, free-form categories,
  display timezone and exact canonical project references.
- Workspace, category and text filters, with scoped active/today/overdue/review
  counts. Identical task IDs in different projects remain distinct.
- Existing blueprint workflows appear as templates. Opening a workflow leads
  to the current signed workflow-run controls; no scheduler is implied.
- Task and project links return to `/app` and its existing device signing,
  checklists, evidence, review and lifecycle commands. A `focus` query only
  highlights the requested task card; it cannot submit an action.
- `GET /api/v1/operations`: a fresh cookie-authenticated snapshot from the
  canonical task projections, containing only projects the principal can read.
- No seeded operational records or fictitious example users. An unconfigured
  deployment has an empty view.

Assignments, human-reported blockers, recurring execution, household shopping
metadata and embedded multiuser procurement are not delivered by this increment.
The interface does not expose controls that pretend those capabilities exist.

## Configuration

Copy [`config/operations.example.json`](../../config/operations.example.json)
to an installation-specific file. Replace its placeholder references with
existing projects and choose labels appropriate to the installation. Set:

```sh
export TASK_HOST_OPERATIONS_CONFIG=/absolute/path/to/operations.json
```

The existing task-host or orchestration release reads this file at startup.
Restart that release after changing the catalogue. The setting does not start
an application, migrate a database, create projects, issue grants or install
an identity provider. Follow the existing [deployment runbook](../deploy.md)
for those responsibilities.

Schema 1 is closed: unknown keys are rejected. The file is at most 64 KiB and
contains at most 32 workspaces. Workspace IDs and exact scope triples must both
be unique. Strings have explicit bounds. IDs use the existing safe-segment
alphabet, with no slashes, traversal components or URL destinations.

| Field | Meaning | Default |
| --- | --- | --- |
| `schema_version` | Configuration version; required | `1` |
| `title` | Application display name | `Operations` |
| `time_zone` | IANA timezone used to group and display dates | `Etc/UTC` |
| `workspaces` | Required list of configured existing projects | Empty when no file is selected |
| `workspaces[].id` | Stable presentation identity; required | None |
| `workspaces[].label` | User-facing workspace name; required | None |
| `workspaces[].category` | Arbitrary display/filter label | `general` |
| `chapter_id`, `tenant_id`, `project_id` | Exact canonical project scope; required | None |

The backend bounds and checks timezone syntax. The browser validates it with
its actual `Intl` timezone database before displaying date groups. An unknown
zone makes the view unavailable instead of silently using another zone. This
display setting is not a recurrence execution policy.

For an embedded/configured host, the equivalent string-keyed map can be set
with `config :task_host, :operations, map`. A selected JSON file takes
precedence. A missing setting preserves the existing application configuration.
A read, decode, size or schema failure returns a generic 503 for authenticated
snapshot requests and discloses neither the file path nor its content.

The current sign-in provider can be selected with
`/operations?provider=<configured-provider>`; the default follows the existing
task UI's `workos` convention. Web sign-in retains the host's existing
`:after_login_path`. A deployment using Operations as its home page can set:

```elixir
config :task_host, :after_login_path, "/operations"
```

No arbitrary return URL is added. Existing deployments can retain their login
destination and link to `/operations`.

## Authorization and disclosure

`TaskHost.Operations.snapshot/3` uses one supplied `Log.gate()` value for both
authorization and projection. It first applies the existing
`CoopSubstrate.Feed.Access.for_principal/3`, then the existing chapter
administrator fallback. Only then does it select the project's whitelisted
`tasks`, `suggestions` and `workflows` projections.

Unauthorized workspace labels, categories, IDs, scope references and data are
omitted. There is no total configured-workspace count or unauthorized placeholder
that reveals their existence. The API ignores request-supplied scope/principal/
configuration parameters. The session is rechecked before the response is sent.
Responses are `Cache-Control: no-store`; no task data enters browser storage.

Existing chapter-governance breadth is preserved: a declared chapter
administrator can read that chapter's configured projects. If two audiences
must not share that authority, provision the appropriate separate governance
boundaries. Category and label values never narrow or widen grants. Household
labels do not enroll commercial participants or authorize procurement.

The server response is a point-in-time read. The browser replaces the entire
snapshot every 15 seconds while visible, and on manual refresh or return to the
page. Revoked access disappears on the next successful authorized snapshot;
this is not a push-based instantaneous revocation claim. Errors clear visible
records and summaries. Hidden pages, page exit and logout clear data; request
generations prevent late responses from restoring it. Logout blocks refresh
until its real identity request completes. A ten-second request timeout bounds
an unavailable refresh. Existing domain commands continue to check current
authority independently.

The read view does not assert that a person is an assignee or reviewer merely
because they may read a project. It shows facts such as pending evidence review
and links to the authoritative action surface. It does not reuse the existing
device-specific `nextStep` helper without a device key.

## Timing and lifecycle semantics

- Today includes unfinished tasks that are overdue, due today, scheduled
  across today, or in progress.
- Upcoming covers the next seven calendar days, from tomorrow through today
  plus seven days in the configured timezone, including overlapping schedules.
- Overdue means an unfinished task with `due_ms < now`. A past scheduled start
  is not an invented deadline.
- All-day `end_date` and timed `end_ms` are exclusive. Timed intervals are
  grouped using the configured timezone, including daylight-saving changes.
- Unscheduled means no due date and no schedule. Malformed timing is indicated
  explicitly rather than reclassified as missing.
- Completed and cancelled tasks do not inflate active/overdue totals. They
  remain available in the Closed view with their actual state.
- Timing and review badges are separate from the canonical lifecycle.
  Checking off a todo does not bypass parent-task completion requirements.

## Remaining customizable product increments

| Stage | Implementation obligation | Acceptance |
| --- | --- | --- |
| FO-02 | Admitted assignment and human-reported blocker facets; typed request setup | Assignment is distinct from project ownership and grants; stale writes and unauthorized changes refused. |
| FO-03 | Versioned daily/weekly routines and a bounded scheduler over existing workflow instantiation | Atomic uniqueness per routine/intended local date; edits preserve existing occurrences; pause/revocation/restart/DST controls. |
| FO-04 | Household shopping metadata and a working authorized business procurement entry point | Household labels confer no B2B enrollment; buyer/payer and payment/receipt evidence stay distinct. |
| FO-05 | Private deployment, onboarding, backup/restore, exports, weekly exception review | Persisted multiuser workflow exercised on the selected installation without developer shortcuts. |

Each installation should select its own request catalogues, workflow templates
and authority assignments through the existing governed mechanisms. Optional
templates can describe maintenance, administration, service work or household
routines; none is a mandatory business type. Future settings must not redefine
canonical lifecycle transitions, turn ownership into authority, or waive
completion evidence through presentation configuration.

## Validation

The focused checks are:

```sh
node --test apps/task_host/test/js/*.test.mjs
cd apps/task_host
mix test test/task_host/operations_test.exs test/task_host/web/operations_test.exs
mix test test/task_host/web/operations_browser_test.exs --include browser
```

The browser test uses the actual identity endpoints, task-host HTTP snapshot,
and signed ledger fixtures in separately governed chapters. It verifies
custom labels/categories, scope collisions, restricted reads, literal text
rendering, mobile 390px layout, real grant revocation and logout. It neither
mocks the API nor treats read access as action authority.

The dedicated [Operations workspace acceptance workflow](../../.github/workflows/operations-workspace-acceptance.yml)
runs these contracts separately from unrelated umbrella acceptance. Its source
revision, compilation result and test results remain distinct from deployment
evidence. No live installation, real family data or production writer cutover
is established by a fixture-based test.
