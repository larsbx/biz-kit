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

## Still to reconcile

The [architecture decision matrix](docs/architecture/2026-10-09-integration-decisions.md)
reviews the implementations behind these choices and proposes an integration
path. It recommends retaining domain authorities with adapters, sharing selected
infrastructure, and addressing production isolation first. The recommendations
remain subject to review; no migration or production behavior changes with the
documentation.

1. **Event storage and authority.** `coop_substrate` uses Commanded's
   `eventstore` library (chosen after an AshEvents spike), without full
   Commanded aggregates. `spruce_goose` uses `ash_events` for notes and a
   separate PostgreSQL certified-event ledger for orchestration shadow history;
   Ash/PostgreSQL remains its live task authority. `SpruceGoose.Identity` has
   an adapter seam for the cooperative log; only `Identity.Local` exists today.
2. **Identity.** `dispatch` (OIDC) and `spruce_goose` (ash_authentication
   tokens and OAuth2) have separate models.
3. **Shared environment variables in production.** `DATABASE_URL`,
   `POOL_SIZE` and `SECRET_KEY_BASE` are read by both `dispatch` and
   `spruce_goose`. Both default their HTTP port to 4000 (`PORT` / `MCP_PORT`).
   Two Ecto repos pointed at one database would share `schema_migrations`.
4. **Keel and the ledger.** Ownership changes in `keel` (transfer, withdrawal,
   dissolution) should be appended as signed `coop_substrate` events.
5. **Optional apps.** `truck-shop` (Phoenix 1.7, Elixir 1.16; overlaps
   dispatch's fleet domain) and `spruce` (agent supervision; overlaps
   spruce_goose).
