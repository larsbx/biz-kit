# Deploying

For the dormant adder-ws event-driven trigger, see
[activation and host acceptance](adder-ws-cd.md). HTTP trigger acceptance does
not establish successful deployment.

Date: 2026-10-20. The shortest path to a running deployment.

## Releases

| Release | Applications | Boots in production when |
| --- | --- | --- |
| `orchestration` | the ledger (`coop_substrate`), identity, cluster, SpruceGoose (web view, API, CLI service) | the settings below are set |
| `biz_kit` | all of the above, plus `dispatch` and `keel` | dispatch's integrations are configured too |
| `eatsbot` | `eatsbot` and its `eatsbot_*` siblings | `DATABASE_URL`, `SECRET_KEY_BASE`, `GEOCODING_TOKEN`, `TOKEN_SIGNING_SECRET` are set |
| `restaurant` | the ledger and the rebuilt eatsbot's host (`restaurant_host`) | the [restaurant settings](#the-restaurant-release) are set |

`eatsbot` is built from its own directory, so it compiles only eatsbot and its
siblings: `docker build -f apps/eatsbot/Dockerfile .` from the repository root.
It has a database of its own. Its production section of `runtime.exs` runs
only for this release (or an unset `RELEASE_NAME`), and the dispatch and
SpruceGoose sections skip it.

Production eatsbot is not deployed from here: Fly deploys it from
`larsbx/eatsbot`, which remains the source of truth (see the
[modular platform decision](architecture/2026-10-24-modular-business-platform.md)).
Moving production to this release is a separate, tested cutover; until then
this release exists for building and testing, and must not run as a second
writer against eatsbot's production database.

The Telegram bot reads `TELEGRAM_BOT_TOKEN` and `TELEGRAM_WEBHOOK` (the full
`https://…/telegram` URL) at boot. Setting `TELEGRAM_WEBHOOK` also requires
`TELEGRAM_WEBHOOK_SECRET` (1–256 of `A-Z a-z 0-9 _ -`): the bot registers it
with Telegram, and `POST /telegram` answers 401 to any update without it.

Nothing depends on dispatch, so `orchestration` leaves it out. In
production, dispatch refuses to start until it has these:
- production adapters for geo routing and geocoding, messaging and voice,
  and the agent runtime;
- distinct breakglass requester and approver entitlements;
- `DISPATCH_CAPABILITY_SIGNING_SEED`.

`runtime.exs` skips dispatch's production section when `RELEASE_NAME` is
`orchestration`. Use `biz_kit` once dispatch has its integrations. Until the
consolidation moves dispatch onto the ledger, give it a database of its own:
both releases read `DATABASE_URL`.

## Steps

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release orchestration
# copy _build/prod/rel/orchestration to the host (it includes ERTS), then:
bin/orchestration eval "SpruceGoose.ReleaseTasks.migrate()"   # before every start; idempotent
bin/orchestration daemon                                       # or a systemd unit running `start`
```

`SpruceGoose.ReleaseTasks.migrate/0`:
1. creates and initializes the ledger's event store database, if needed;
2. creates SpruceGoose's database, if needed;
3. applies pending migrations.

Migrations never run on boot.

## Settings

| Variable | For |
| --- | --- |
| `DATABASE_URL`, `DATABASE_SSL` (default `true`), `DATABASE_CA_CERT_FILE` | SpruceGoose's database |
| `EVENTSTORE_HOST`, `EVENTSTORE_PORT`, `EVENTSTORE_DATABASE`, `EVENTSTORE_USERNAME`, `EVENTSTORE_PASSWORD` | the ledger |
| `SECRET_KEY_BASE` (≥ 64 bytes), `TOKEN_SIGNING_SECRET`, `OAUTH2_SIGNING_SECRET` | sessions and tokens |
| `SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR` | the first operator SpruceGoose's registry accepts |
| `SPRUCE_GOOSE_MCP_ENABLED=true`, `MCP_PORT`, `SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS` | serve the web view and API, on loopback only. Put a reverse proxy in front, and list it in `SPRUCE_GOOSE_TRUSTED_PROXIES` |
| `SPRUCE_GOOSE_PUBLIC_URL`, `WORKOS_CLIENT_ID`, `WORKOS_API_KEY`, `BIZKIT_IDENTITY_BINDINGS` | sign-in (`docs/architecture/2026-10-18-identity.md`) |
| `ARTIFACT_STORE_ROOT` (default `/var/lib/sprucegoose/artifacts`) | uploaded evidence, SOPs and inputs |
| `BIZKIT_CLUSTER_NODES`, `RELEASE_DISTRIBUTION`, `RELEASE_NODE`, `RELEASE_COOKIE` | several nodes (`docs/architecture/2026-10-19-cluster.md`) |
| `SPRUCE_GOOSE_OBAN_ENABLED` (default `true`) | SpruceGoose's job queue |

**The Systemwide SOP file** is needed only when the legacy CLI writer runs
(`SPRUCE_GOOSE_CLI_SERVICE_ENABLED=true`). That writer gates work on the file
at `SYSTEMWIDE_SOP_PATH` and checks it at boot against the digest in
`apps/spruce_goose/priv/constitution/adopted.json`. The ledger does not read
the file: each task's readiness definition names its SOP by digest.

## The restaurant release

The rebuilt eatsbot: a cash-only storefront and kitchen board whose every
order step is a device-signed event admitted by the ledger. It has no database
of its own, only the ledger's event store, and it never shares Dispatch's or
SpruceGoose's settings: `runtime.exs` skips their sections for it.

```sh
MIX_ENV=prod mix release restaurant
bin/restaurant eval "RestaurantHost.ReleaseTasks.migrate()"   # initializes the ledger; idempotent
bin/restaurant daemon
```

| Variable | For |
| --- | --- |
| `RESTAURANT_PUBLIC_BASE_URL` | the public URL; the live pages' websocket origin check compares against its host |
| `RESTAURANT_SECRET_KEY_BASE` (≥ 64 bytes) | the signed session that holds a paired board |
| `RESTAURANT_PORT` (default `4070`) | the listening port, behind a TLS-terminating proxy |
| `RESTAURANT_CONFIG_FILE` | the restaurant file (below) |
| `RESTAURANT_DEVICE_SEED_<DEVICE_ID>` | each device's 32-byte signing seed, base64; `<DEVICE_ID>` upper-cased with other characters as `_` |
| `EVENTSTORE_*` | the ledger, as above |

The restaurant file names the ledger chapter, merchant, currency, tax rate,
menu and devices. It holds no secret: seeds come only from the environment, and
a board's pairing secret only as its SHA-256.

```json
{
  "chapter": "chapter-genesis",
  "merchant": "shop",
  "currency": "USD",
  "tax_rate": "0.0825",
  "menu": [{"id": "margherita", "name": "Margherita", "sku": "MARG", "price_minor": 1250}],
  "storefront": {"device_id": "storefront", "key_id": "k-store"},
  "boards": {"board-1": {"device_id": "board-1", "key_id": "k-board", "pairing_sha256": "<hex>"}}
}
```

The host validates all of it at boot (`RestaurantHost.Config`) and refuses to
start on any error. Each device's key must also be granted on the ledger by
the chapter's governance key (`RestaurantDeviceGrantedV1`: the storefront
`checkout`, a board its kitchen steps); until then the ledger refuses what it
signs. Pair a board by opening `/board/pair/<board>/<secret>` on it once.

## Testing a deployment

`scripts/release-smoke.sh` is what the `release-smoke` CI job runs, and it
runs the same way locally against a PostgreSQL on `localhost`. It:
1. builds the production `orchestration` release;
2. migrates twice;
3. boots the release;
4. waits for the web view;
5. runs `scripts/release_smoke.exs` inside the release.

The script signs task commands on the release's own ledger and checks:
- todos, a dependency refused while open, and the feed view;
- a predecessor cycle refused;
- SOP versions that never go back;
- replay reproducing the state that admission saw.

`scripts/restaurant-release-smoke.sh` does the same for the `restaurant`
release (the `release-smoke` job of `restaurant-core.yml`): build, migrate
twice, boot, check the storefront and board pairing over HTTP, then place and
complete a pickup order on the release's own ledger in a fresh chapter.

## What this does not cover

- **Hosts.** No host, container image or proxy configuration is in this
  repository. The standalone SpruceGoose production on Mama is deployed
  from the `sprucegoose` repository (`ops/mama-authority`), not from here.
- **The production writer.** Switching it to the ledger is consolidation
  step 5 (`docs/roadmap.md`).
