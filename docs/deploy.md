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
| `RESTAURANT_SECRET_KEY_BASE` (≥ 64 bytes) | signs the browser session for board pairing and customer sign-in |
| `RESTAURANT_PORT` (default `4070`), `RESTAURANT_BIND_IP` (default `0.0.0.0`; `::` for IPv6, `127.0.0.1` behind a local proxy) | where it listens, behind a TLS-terminating proxy |
| `RESTAURANT_CONFIG_FILE` | the restaurant file (below) |
| `WORKOS_CLIENT_ID`, `WORKOS_API_KEY`, `BIZKIT_IDENTITY_BINDINGS` | optional account sign-in using existing Biz-kit principal bindings. Register `<RESTAURANT_PUBLIC_BASE_URL>/auth/callback` with WorkOS. |
| `RESTAURANT_STAFF_PRINCIPALS` | comma-separated Biz-kit principal IDs. When present, a board requires both pairing and staff sign-in. An empty list denies every staff principal. |
| `RESTAURANT_DEVICE_SEED_<DEVICE_ID>` | each device's 32-byte signing seed, base64; `<DEVICE_ID>` upper-cased with other characters as `_` |
| `EVENTSTORE_*` | the ledger, as above |

The restaurant file names the ledger chapter, merchant, currency, tax jurisdiction (`US-MI`: Michigan, see `CommerceCore.Tax.Jurisdictions`),
menu and devices. It holds no secret: seeds come only from the environment, and
a board's pairing secret only as its SHA-256.

```json
{
  "chapter": "chapter-genesis",
  "merchant": "shop",
  "currency": "USD",
  "jurisdiction": "US-MI",
  "menu": [{"id": "margherita", "name": "Margherita", "sku": "MARG", "price_minor": 1250}],
  "storefront": {"device_id": "storefront", "key_id": "k-store"},
  "boards": {"board-1": {"device_id": "board-1", "key_id": "k-board", "pairing_sha256": "<hex>"}}
}
```

The host validates all of it at boot (`RestaurantHost.Config`) and refuses to
start on any error. Each device's key must also be granted on the ledger by
the chapter's governance key; until then the ledger refuses what it signs.
The chapter must already have its governance key declared by the existing
chapter bootstrap ceremony. Enrollment never declares governance or lets a
device grant itself authority. Keep `HARNESS_KEYS_DIR/governance.seed` (0600)
on the administrator's machine, outside the restaurant file and server
environment. Do not copy it to the restaurant server or use `rpc` to enroll.

From a source checkout on the administrator's machine:

```sh
export HARNESS_KEYS_DIR=/secure/operator-keys
mix restaurant.grant storefront --chapter chapter-genesis --merchant shop --server https://order.example
mix restaurant.grant board-1 --chapter chapter-genesis --merchant shop --server https://order.example
```

Or use a copy of the built `restaurant` release on the administrator's machine
without Mix (with its normal public URL, endpoint secret and restaurant-file
path settings loaded; device seeds and event-store credentials are unnecessary
because `eval` does not start the host or ledger):

```sh
bin/restaurant eval 'RestaurantHost.ReleaseTasks.grant(["storefront", "--chapter", "chapter-genesis", "--merchant", "shop", "--server", "https://order.example"])'
bin/restaurant eval 'RestaurantHost.ReleaseTasks.grant(["board-1", "--chapter", "chapter-genesis", "--merchant", "shop", "--server", "https://order.example"])'
```

Both commands show chapter, merchant, device identifier, key identifier,
public key and exact permissions before asking for confirmation. Review them
against the deployment's expected device keys. The storefront receives only
`system` / `checkout`; boards receive `staff` / `accept`, `start_preparing`,
`mark_ready`, `complete`, `cancel`. A board's pairing secret controls access to
the board UI; its governance grant separately authorizes ledger events.
`--yes` skips the interactive question for reviewed automation, but still
requires explicit chapter and merchant and verifies the exact signed proposal.
Remote servers require HTTPS; HTTP is accepted only on loopback.

Preparing a grant also requires a signed governance HTTP request with a fresh
nonce; anonymous requests cannot fill or evict enrollment holds.
The host holds a grant for five minutes, bound to chapter, merchant and the
configured device key. The client checks the canonical bytes match the
reviewed grant and governance signer, then sends only a signature. Submission
is single-use; expired, replayed, unauthorized or malformed grants cannot
append. A repeat enrollment is refused as already granted. For refusal,
check chapter governance, device configuration, key identifiers and clock
before preparing a new grant. This command does not rotate or revoke keys.
Device IDs, key IDs, chapter and merchant use 1–128 ASCII letters, digits,
`_`, `.` or `-`, starting with a letter or digit. Device IDs, key IDs, derived
seed-variable names and device keys must be distinct in one restaurant.

Then pair a board by opening `/board/pair/<board>/<secret>` on it once.


### Publish a menu or revoke a board key

The restaurant file supplies menu revision 0. A governance publication
replaces the complete menu, including ordering and any removed items. Read
the current revision from `GET /api/restaurant-menu`, then save a command as
JSON on the governance operator's machine. For the first publication:

```json
{
  "merchant_id": "shop",
  "expected_revision": 0,
  "currency": "USD",
  "items": [
    {"id": "margherita", "sku": "MARG", "name": "Margherita",
     "price_minor": 1250, "discount_minor": 250}
  ]
}
```

The optional discount is funded by the restaurant and applied to each unit
before tax. The signed order keeps the original unit price and the applied
line discount. Michigan's treatment of seller-funded discounts is described
in [R 205.22](https://www.michigan.gov/taxes/-/media/Project/Websites/treasury/Rules/R_205-1_to_R_205-141_700772_7.pdf).
An empty `items` list pauses new pickup orders.

```sh
mix restaurant.manage publish-menu menu.json --chapter chapter-genesis --server https://order.example
```

To revoke a board or storefront key, use the JSON
`{"merchant_id":"shop","key_id":"k-board"}` with the same command, replacing
`publish-menu` with `revoke-device`. Replace a revoked key by enrolling a new
key ID. Both operations are available from an operator's release copy:

```sh
bin/restaurant eval 'RestaurantHost.ReleaseTasks.manage(["publish-menu", "menu.json", "--chapter", "chapter-genesis", "--server", "https://order.example"])'
```

The operator's copy uses `HARNESS_KEYS_DIR` as for enrollment. It verifies the
held envelope against the local command before signing, and the running host
submits the signature to the Log.

### Arranged delivery with Dispatch

Set `"delivery_enabled": true` in the restaurant file to offer arranged
delivery after a Dispatch key is enrolled. Keep the default for pickup-only
restaurants. Agree delivery and capture the address and contact in Dispatch
before using the pilot. The restaurant ledger carries opaque references and
the existing order name. Cash remains due at handoff.

Enroll a dedicated Dispatch signing key with the restaurant operator command:

```sh
mix restaurant.manage grant-dispatch dispatch-key.json --chapter chapter-genesis --server https://order.example
```

The JSON names `merchant_id`, `tenant_id` (the Dispatch tenant UUID), `key_id`,
and `pubkey` (base64url without padding). Revoke this key with
`revoke-device`. The signing seed is a base64-encoded 32-byte seed in an
operator-readable file on the Dispatch release machine.

Set these variables in the Dispatch release:

| Variable | Value |
| --- | --- |
| `RESTAURANT_DISPATCH_URL` | Restaurant HTTPS origin |
| `RESTAURANT_DISPATCH_CHAPTER`, `RESTAURANT_DISPATCH_MERCHANT` | Exact enrolled chapter and merchant |
| `RESTAURANT_DISPATCH_TENANT`, `RESTAURANT_DISPATCH_KEY_ID` | Enrolled Dispatch tenant and key ID |
| `RESTAURANT_DISPATCH_SEED_FILE` | Path to the protected seed file |

Use the existing Dispatch board to create a load with external reference
`restaurant:<chapter>:<merchant>:<order-id>`, add pickup and delivery stops,
and activate a driver assignment. After the kitchen marks the order ready,
an operator with access to the Dispatch release can submit the handoff:

```sh
bin/biz_kit rpc ' {:ok, result} = Dispatch.RestaurantDelivery.publish(%{
  "op" => "accept", "order_id" => "ORDER", "load_id" => "LOAD_UUID",
  "assignment_id" => "ASSIGNMENT_UUID", "command_id" => "accept-1", "expected_version" => 0
}); IO.inspect(result)'
```

Use the same load and assignment for the remaining steps:

| Operation | Version | Dispatch source and operator review |
| --- | ---: | --- |
| `picked_up` | 1 | Active or completed assignment and `PICKUP_DOCUMENT` from the load's pickup stop. Supply its UUID as `proof_id` and `"reviewed" => true` after verifying the evidence. |
| `delivered` | 2 | Completed assignment and `PROOF_OF_DELIVERY` from the load's delivery stop. Supply its distinct UUID and attest after review. |

Use a distinct command ID for each step. Repeat the same payload and command
ID after an uncertain response. A signed duplicate does not advance the
handoff again. The kitchen board shows the current handoff version. Once
Dispatch accepts, the board cannot cancel the order. Resolve exceptions with
Dispatch before taking any further action. The pilot has no automatic
routing, address collection in checkout, or post-acceptance cancellation
workflow.

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
twice, boot, check the storefront and board pairing over HTTP, then enroll both
devices with the operator-side release command over HTTP and complete a pickup
order on the release's own ledger in a fresh chapter. Only the initial
governance declaration is bootstrapped; no device grant is manually appended.
The operator VM is checked to have no running ledger and receives no device
seeds; the server receives no governance seed. PostgreSQL 16 is required.

## What this does not cover

- **Hosts.** No host, container image or proxy configuration is in this
  repository. The standalone SpruceGoose production on Mama is deployed
  from the `sprucegoose` repository (`ops/mama-authority`), not from here.
- **The production writer.** Switching it to the ledger is consolidation
  step 5 (`docs/roadmap.md`).
