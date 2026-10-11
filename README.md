# biz-kit

One Mix umbrella, one dependency lock, one release (`biz_kit`) for the
Elixir core of the business platform. Each app was imported with
`git subtree`, so its full history, `git log` and `git blame` are preserved
under its directory.

| App | Path | Imported from | Role |
| --- | --- | --- | --- |
| `keel` | `apps/keel` | `larsbx/keel` | Company-structure primitives: pure functions, no runtime |
| `coop_substrate` | `apps/coop_substrate` | `larsbx/coop_substrate` | Signed, append-only event ledger and capital accounts (Rust NIF via rustler) |
| `dispatch` | `apps/dispatch` | `larsbx/d-patch` (`central/` only) | Dispatch domain: participants, trips, loads, communications |
| `spruce_goose` | `apps/spruce_goose` | `larsbx/sprucegoose` | Task and orchestration control plane (CLI, MCP/OAuth endpoint) |

Mix requires umbrella directory names to equal OTP application names, hence
`coop_substrate` and `spruce_goose`.

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
(cd apps/coop_substrate && mix test)
(cd apps/dispatch       && mix test)                      # unit tier
(cd apps/dispatch       && mix test --include integration) # needs PostGIS
(cd apps/spruce_goose   && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate && mix test)
```

dispatch's test database connects as the Postgres role `dispatch`; create it
(`create role dispatch login superuser;`) on a fresh cluster.

Verified on Elixir 1.19.0 / OTP 27.3.4 / PostgreSQL 16 + PostGIS 3:

| App | Result |
| --- | --- |
| keel | 84 tests, 8 properties, 0 failures |
| coop_substrate | 282 tests, 8 properties, 1 doctest, 0 failures |
| dispatch (with integration tier) | 261 tests, 2 doctests, 0 failures |
| spruce_goose | 523 tests, 0 failures (8 `:separate_sessions` excluded by default) |

## Configuration

- `config/config.exs` imports each app's own `apps/<app>/config/config.exs`,
  which in turn imports its per-environment files.
- `config/runtime.exs` is the single runtime file for the release (releases
  read one runtime file and it may not import others). It holds one section per
  app, moved verbatim from the apps' former `runtime.exs` files. A production
  boot therefore needs every app's required variables; spruce_goose's runtime
  tests supply the other apps' with inert values (`SpruceGoose.UmbrellaRuntime`).

## Merge decisions

- One root `mix.lock`, seeded from the apps' locks (newest version wherever
  they differed) so that resolution moved as little as possible.
- `dispatch`: `ash_authentication ~> 4.0` became `~> 5.0-rc` to match
  `spruce_goose`. dispatch declared the dependency but used none of it.

## Consolidation direction

The target is [one source of truth](docs/architecture/2026-10-11-single-source-of-truth.md):
one signed business-event ledger, one command admission path, one principal
registry, and one PostgreSQL database. Task, dispatch, ownership, and economic
views become rebuildable projections. Domain rules remain organized in modules.

The existing `CoopSubstrate.Log` / `eventstore` implementation is the proposed
common ledger. The plan retires the AshEvents notes spike, the separate
SpruceGoose business-event writer, competing row-write authority, and redundant
identity/configuration machinery as their replacements pass cutover checks.
Permanent cross-ledger bridges are outside the target.

The [first implementation stage](docs/architecture/2026-10-11-first-ledger-task-command.md)
retires the notes/AshEvents spike and adds an isolated signed task proposal on
the common ledger. Full runtime consolidation remains to implement. Dispatch and SpruceGoose
still own live domain rows; their schemas/configuration cannot safely be
combined by pointing both at the same `DATABASE_URL`. The architecture document
defines the removal order, preserved signatures/IDs, and replay/recovery proof.
Optional `truck-shop` and `spruce` imports remain outside this consolidation work.

The [October 9 comparison](docs/architecture/2026-10-09-integration-decisions.md)
retains the implementation evidence and tradeoffs; its recommendation to retain
independent authorities is superseded.

## Buzz workspace integration

The [first Buzz task stage](docs/architecture/2026-10-11-buzz-task-workspace.md)
adds an internal signed-proposal boundary and scoped, replayable task cards
with Definition of Done provenance. It performs no network delivery and does
not yet implement structured evidence review, completion, or a Buzz client UI.
Employees, members and agents use explicit scoped grants; chat/channel access
does not confer business authority.

The [DoD evidence/review stage](docs/architecture/2026-10-11-dod-evidence-review.md)
adds immutable criteria revisions, digest-linked evidence submissions and
independently scoped reviewer grants/decisions on the same ledger. Reviews bind
to exact revisions and submissions; acceptance does not complete the task.
