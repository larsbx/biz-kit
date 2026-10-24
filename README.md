# biz-kit

One Mix umbrella and one dependency lock for the Elixir core of the business
platform, with three release profiles: `biz_kit`, `orchestration` and `eatsbot`.
The domain apps below were imported with their full history, so `git log` and
`git blame` work under each directory: the first four with `git subtree`,
eatsbot with `git filter-repo` (see below).
The read-only `school_ops` curriculum app is a version-pinned content
snapshot: it records its upstream commit rather than claiming a subtree history
import.

| App | Path | Imported from | Role |
| --- | --- | --- | --- |
| `keel` | `apps/keel` | `larsbx/keel` | Company-structure primitives: pure functions, no runtime |
| `coop_substrate` | `apps/coop_substrate` | `larsbx/coop_substrate` | Signed, append-only event ledger and capital accounts (Rust NIF via rustler) |
| `dispatch` | `apps/dispatch` | `larsbx/d-patch` (`central/` only) | Dispatch domain: participants, trips, loads, communications. Its server work continues here; d-patch keeps the clients |
| `spruce_goose` | `apps/spruce_goose` | `larsbx/sprucegoose` | Task/workflow views, web/MCP endpoint, and the legacy orchestration writer |
| `eatsbot` | `apps/eatsbot` | `larsbx/eatsbot` (`tololo/`, then `eatsbot/`) | Restaurant ordering: storefront GraphQL API, back office, orders, deliveries. Its own release and database |
| `eatsbot_core`, `eatsbot_extension_*` | `apps/eatsbot_core`, `apps/eatsbot_extension_{kafka,prometheus,telegram_bot}` | `larsbx/eatsbot` (eatsbot's former path dependencies) | eatsbot's domain resources, and its Kafka, Prometheus and Telegram extensions |

Shared apps developed in this umbrella:

| App | Path | Role |
| --- | --- | --- |
| `task_core` | `apps/task_core` | Dependency-free task/workflow rules and command admission |
| `commerce_core` | `apps/commerce_core` | Reusable commercial price arithmetic; extracted from Eatsbot with unchanged compatibility API |
| `biz_kit_identity` | `apps/biz_kit_identity` | Stable platform principals, authentication-provider adapters and revocable sessions |
| `biz_kit_cluster` | `apps/biz_kit_cluster` | Cluster membership and singleton coordination |
| `school_ops` | `apps/school_ops` | School domain: K–12 curriculum catalog, lesson/assessment review, and TaskCore-based staff workflows |

Mix requires umbrella directory names to equal OTP application names, hence
`coop_substrate`, `spruce_goose` and the `eatsbot_*` siblings. eatsbot's
directory was renamed during its life, so it was imported with `git filter-repo`
mapping both paths onto `apps/eatsbot` rather than with `git subtree`; all 133
commits that touched it keep their authors, dates and messages.

Not included, by design: the Android, web and e2e clients of `d-patch`
(separate clients of this backend); `agent-runtime-platform` (Python and
Podman sandbox, reached through dispatch's Hermes adapter); `bizops-kb`
(content, not code); `truck-shop` and `spruce` (optional, see below).

## Toolchain

- Elixir 1.19, Erlang/OTP 27
- Rust (for `coop_substrate`'s `canonical_v1` NIF)
- PostgreSQL 16; PostGIS for `dispatch`'s integration tier

## Build and test

```sh
mix deps.get
mix compile

# Per app, from its directory:
(cd apps/keel           && mix test)
(cd apps/task_core      && mix test)
(cd apps/commerce_core   && mix test --no-start)           # pure arithmetic, no umbrella runtime
(cd apps/coop_substrate && mix test)
(cd apps/biz_kit_identity && mix test)
(cd apps/biz_kit_cluster  && mix test)
(cd apps/dispatch       && mix test)                      # unit tier
(cd apps/dispatch       && mix test --include integration) # needs PostGIS
(cd apps/spruce_goose   && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate && mix test)
(cd apps/eatsbot        && MIX_ENV=test mix ash.setup && ADMIN_API_KEY=test mix test)
(cd apps/school_ops     && mix test)                        # no database required
```

dispatch's test database connects as the Postgres role `dispatch`; create it
(`create role dispatch login superuser;`) on a fresh cluster.

### Historical import validation

[PR #1](https://github.com/larsbx/biz-kit/pull/1), merged on October 9, reported
these results on Elixir 1.19.0 / OTP 27.3.4 / PostgreSQL 16 + PostGIS 3 at
import head `343175fc580590311fbe184b7cb550076c2738a7`. These are historical
counts, not the current suite size or a fresh validation run.

| App | Result |
| --- | --- |
| keel | 84 tests, 8 properties, 0 failures |
| coop_substrate | 282 tests, 8 properties, 1 doctest, 0 failures |
| dispatch (with integration tier) | 261 tests, 2 doctests, 0 failures |
| spruce_goose | 523 tests, 0 failures (8 `:separate_sessions` excluded by default) |

Current checks are defined in [Consolidation](.github/workflows/consolidation.yml),
[Portal authentication acceptance](.github/workflows/portal-auth-acceptance.yml)
and [Location cross-repository acceptance](.github/workflows/location-cross-repo-acceptance.yml).
Use the run for the revision being evaluated; a passing unit tier does not
establish integration, production deployment or complete writer cutover.

## Deploying

The root [mix.exs](mix.exs) defines both profiles from the same source and lock:

| Release | Includes | Build |
| --- | --- | --- |
| `orchestration` | Ledger, identity, cluster and SpruceGoose; excludes Dispatch | `MIX_ENV=prod mix release orchestration` |
| `biz_kit` | The above plus Dispatch and Keel | `MIX_ENV=prod mix release biz_kit` |

[docs/deploy.md](docs/deploy.md) describes settings, migration limits and
`scripts/release-smoke.sh`, which builds, boots and exercises `orchestration`.
Building the full profile is not evidence that the imported databases or
production writers have been consolidated.

## Configuration

- `config/config.exs` imports each app's own `apps/<app>/config/config.exs`,
  which in turn imports its per-environment files.
- `config/runtime.exs` is the shared, release-aware runtime entry point.
  `RELEASE_NAME=orchestration` skips Dispatch's production requirements;
  the full `biz_kit` profile also requires Dispatch's configuration.
  SpruceGoose's isolated runtime tests use inert peer settings
  (`SpruceGoose.UmbrellaRuntime`); those fixtures are not deployment evidence.
- Dispatch and SpruceGoose still read shared `DATABASE_URL`, `POOL_SIZE` and
  `SECRET_KEY_BASE` variables, and their HTTP listeners both default to 4000
  (`PORT` / `MCP_PORT`). Their conflicting tables and migration histories
  prevent a safe shared-schema deployment. Isolation is a migration boundary;
  the selected destination is one reconciled database, not permanent separate
  authorities. See the [database contract](docs/architecture/2026-10-11-single-source-of-truth.md#commands-and-projections)
  before changing connection targets or assuming a shared transaction.

## Merge decisions

- One root `mix.lock`, seeded from the apps' locks (newest version wherever
  they differed) so that resolution moved as little as possible.
- `dispatch`: `ash_authentication ~> 4.0` became `~> 5.0-rc` to match
  `spruce_goose`. dispatch declared the dependency but used none of it.
- `eatsbot`: `ash_authentication` 4 → `~> 5.0-rc` (its token resource now
  declares the actions v5 no longer generates) and `phoenix` 1.7 → `~> 1.8`, to
  match the umbrella. Its Ash tracer is installed when eatsbot starts, not in
  shared config: the other apps do not carry `opentelemetry_ash`.
- `telegex` is vendored under `vendor/telegex` with a one-line guard fix; a
  clean umbrella build otherwise fails depending on compile order
  (`vendor/telegex/VENDOR.md`).
- `config/runtime.exs` gates each app's production section on the release that
  ships it (`RELEASE_NAME`), so no release needs another's secrets.
- `dispatch` signs with the ledger's scheme (`coop_substrate`, code only), and
  its OpenAPI contract is `apps/dispatch/contracts/openapi.json` — the
  d-patch field app's DTOs are held to a copy of it.

## Roadmap

[docs/roadmap.md](docs/roadmap.md): what is delivered, what comes next and
in what order, the remaining consolidation steps, and open questions.

## Consolidation direction

The target is [one source of truth](docs/architecture/2026-10-11-single-source-of-truth.md):
one signed business-event ledger, one command admission path, one principal
registry, and one PostgreSQL database. Task, dispatch, ownership, and economic
views become rebuildable projections. Domain rules remain organized in modules.

`CoopSubstrate.Log` / `eventstore` already backs the delivered common-ledger
task path. The AshEvents notes spike and dependency are retired; that spike was
not SpruceGoose's task ledger. Its separate PostgreSQL `certified_events`
shadow history and its live domain-row writer are different mechanisms whose
retirement remains part of cutover. Permanent cross-ledger bridges are outside
the target.

The [roadmap](docs/roadmap.md) places the project in consolidation step 3,
inside an isolated instance. Task execution/completion and retained task rules
are implemented there. The production writer has not been switched; Dispatch,
Keel ownership and the remaining orchestration writes still need migration.
The architecture's [current boundaries](docs/architecture/2026-10-11-single-source-of-truth.md#delivered-work-and-remaining-boundaries)
and [cutover criteria](docs/architecture/2026-10-11-single-source-of-truth.md#cutover-proof-and-completion)
separate delivered code from production acceptance. Optional `truck-shop` and
`spruce` imports remain outside this consolidation work.

The [October 9 comparison](docs/architecture/2026-10-09-integration-decisions.md)
retains the implementation evidence and tradeoffs; its recommendation to retain
independent authorities is superseded. The selected contract also makes explicit
[transaction/replay](docs/architecture/2026-10-11-single-source-of-truth.md#commands-and-projections),
[ownership admission](docs/architecture/2026-10-11-single-source-of-truth.md#keel-ownership-admission)
and [signature, checkpoint and identity guarantees](docs/architecture/2026-10-11-single-source-of-truth.md#signatures-identifiers-and-identity).

## Buzz workspace integration

The [first Buzz task stage](docs/architecture/2026-10-11-buzz-task-workspace.md)
introduced an internal signed-proposal boundary and scoped, replayable task
cards with Definition of Done provenance. Its proposal-only scope describes
October 11; subsequent stages added evidence review and completion below.
That initial boundary did not deliver network integration or a Buzz client UI.
Employees, members and agents use explicit scoped grants; chat/channel access
does not confer business authority.

The [DoD evidence/review stage](docs/architecture/2026-10-11-dod-evidence-review.md)
adds immutable criteria revisions, digest-linked evidence submissions and
independently scoped reviewer grants/decisions on the same ledger. Reviews bind
to exact revisions and submissions; acceptance does not complete the task.

The [artifact custody stage](docs/architecture/2026-10-12-artifact-custody.md)
adds scoped verified receipts using the existing out-of-log store and common
ledger. V2 evidence binds those receipts; availability and review acceptance
remain distinct from authorized completion.

The [queued/ready rehearsal stage](docs/architecture/2026-10-14-ledger-task-readiness.md)
adds governance-defined prerequisites, personal SOP acknowledgments, and scoped
operator transitions from committed ledger state. The later
[execution stage](docs/architecture/2026-10-19-execution.md) adds start,
evidence, independent review and authorized completion; the
[retained task rules](docs/architecture/2026-10-20-sprucegoose-salvage.md) include
todo completion gates, predecessor-cycle rejection and monotone SOP versions.
These delivered stages do not establish production writer fencing or cutover.

## School operations

[`school_ops`](apps/school_ops/README.md) is a **peer domain app** within
biz-kit, following the same pattern as Dispatch and other domains. It shares
TaskCore's tasks, dependencies, Definition of Done, evidence/review and workflow
planning and relies on the platform's identity, scoped grants and signed ledger
for admitted changes. School-specific features include a stable-ID curriculum
catalog and a Grade 2 staff workflow for scope, resources, lessons, assessment
readiness and weekly planning. These are additions to common task management,
not a separate task manager or a project migration.

Reviewed K–12 curriculum content is bundled at a pinned source commit;
Trivium/Quadrivium pedagogical decisions, source IDs and distinct material
readiness rules remain intact. No private learner records or independent writer
are introduced. The first workflow is a **pure proposal**, not an authorized
task-run or deployed school portal. See
[the SchoolOps domain contract](docs/architecture/2026-10-23-school-ops.md).

## Composable business capabilities

[Modular business platform decision](docs/architecture/2026-10-24-modular-business-platform.md):
biz-kit maintains shared technical and business capabilities, while Eatsbot,
d-patch and SchoolOps remain independently evolvable domain products. The first
small, behavior-preserving extraction is [commerce_core](apps/commerce_core/README.md):
Eatsbot's order pricing algorithm now has a reusable owner and a compatibility
facade. **Inventory, CRM, marketing, general order admission and cross-domain
Dispatch fulfillment are not yet extracted or implemented.** Existing Eatsbot
orders and delivery state remain authoritative in their current deployment;
this change performs no data movement or writer cutover.
