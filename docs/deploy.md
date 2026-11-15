# Deploying

For the dormant adder-ws event-driven trigger, see
[activation and host acceptance](adder-ws-cd.md). HTTP trigger acceptance does
not establish successful deployment.

Date: 2026-10-20. The shortest path to a running deployment.

## Releases

| Release | Applications | Boots in production when |
| --- | --- | --- |
| `orchestration` | the ledger (`coop_substrate`), identity, cluster, the task host (`task_host`: sign-in, web view, API, change feed), SpruceGoose (CLI service, until it retires) | the settings below are set |
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
The replacement is the separate `restaurant` release described below. The
umbrella `eatsbot` release exists for legacy build and compatibility checks.
Keep production order writes on the existing deployment until the
[cutover gates](architecture/2026-11-07-eatsbot-decommission.md#migration-status-as-of-november-14-2026)
are met. The replacement starts with an empty restaurant ledger.

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
bin/orchestration eval "TaskHost.ReleaseTasks.migrate()"      # likewise
bin/orchestration daemon                                       # or a systemd unit running `start`
```

Each migrate task creates and initializes the ledger's event store database
if needed, creates its own database if needed, and applies pending
migrations. The task host's only table holds native apps' sessions; pointed
at SpruceGoose's database (the default, `DATABASE_URL`), it finds the table
already there and every signed-in device stays signed in.

Migrations never run on boot.

## Settings

| Variable | For |
| --- | --- |
| `DATABASE_URL`, `DATABASE_SSL` (default `true`), `DATABASE_CA_CERT_FILE` | SpruceGoose's database, and the task host's unless `TASK_HOST_DATABASE_URL` names another |
| `EVENTSTORE_HOST`, `EVENTSTORE_PORT`, `EVENTSTORE_DATABASE`, `EVENTSTORE_USERNAME`, `EVENTSTORE_PASSWORD` | the ledger |
| `SECRET_KEY_BASE` (≥ 64 bytes), `TOKEN_SIGNING_SECRET` | sessions and tokens |
| `SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR` | the first operator SpruceGoose's registry accepts |
| `TASK_HOST_PORT` (default `4001`; `MCP_PORT` if set) | the task host's sign-in, web view and API, on loopback only. Put a reverse proxy in front, and list it in `SPRUCE_GOOSE_TRUSTED_PROXIES` |
| `SPRUCE_GOOSE_PUBLIC_URL`, `WORKOS_CLIENT_ID`, `WORKOS_API_KEY`, `BIZKIT_IDENTITY_BINDINGS` | sign-in (`docs/architecture/2026-10-18-identity.md`) |
| `COOP_ARTIFACT_DIR` | the bytes ledger custody receipts name (uploaded evidence, SOPs and inputs). Unset, `priv/artifacts` under the release's working directory: set it, and keep the bytes with it when moving |
| `ARTIFACT_STORE_ROOT` (default `/var/lib/sprucegoose/artifacts`) | SpruceGoose's legacy artifact store |
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

### Automated restaurant delivery with Dispatch

Set `"delivery_enabled": true` and `"delivery_site": "North building desk"`
in the restaurant file. The site is the approved drop-off destination
shown to signed-in customers. The initial profile runs one configured pickup
and drop-off route with one authorized courier. Delivery is cash at handoff.

Enroll a dedicated Dispatch key with
`mix restaurant.manage grant-dispatch dispatch-key.json --chapter chapter-genesis --server https://order.example`.
The JSON contains `merchant_id`, `tenant_id` (Dispatch UUID), `key_id` and
`pubkey` (base64url without padding). The key can be revoked with
`revoke-device`. The seed is a base64-encoded 32-byte seed in a protected
file on the Dispatch machine.

| Dispatch release variable | Value |
| --- | --- |
| `RESTAURANT_DISPATCH_AUTOMATED` | `true` starts the reconciler |
| `RESTAURANT_DISPATCH_URL` | Restaurant HTTPS origin |
| `RESTAURANT_DISPATCH_CHAPTER`, `RESTAURANT_DISPATCH_MERCHANT` | Enrolled restaurant scope |
| `RESTAURANT_DISPATCH_TENANT`, `RESTAURANT_DISPATCH_KEY_ID` | Enrolled Dispatch tenant and key |
| `RESTAURANT_DISPATCH_SEED_FILE` | Protected signing-seed file |
| `RESTAURANT_DISPATCH_SERVICE_ROLE` | Organization-scoped Dispatch service role assignment UUID with the board's load, stop and trip capabilities |
| `RESTAURANT_DISPATCH_COURIER` | Participant UUID for a courier holding a driving role in that organization |
| `RESTAURANT_DISPATCH_SITE` | Exact restaurant `delivery_site` value |
| `RESTAURANT_DISPATCH_PICKUP`, `RESTAURANT_DISPATCH_DROPOFF` | Approved Dispatch stop addresses |

Provision the service assignment with the existing Dispatch `:grant` action
during release setup. Use a dedicated `SERVICE` principal, the carrier's
organization scope, and a dispatcher role definition. Dispatch revalidates
this assignment for each write and records it in the audit trail.

When a delivery order becomes ready, Dispatch creates the load and stops,
plans the available courier's trip, submits signed acceptance, then activates
the trip. A busy courier leaves the order queued. The restaurant ledger is
the retry source after restart. Dispatch cancels a planned trip when kitchen
cancellation wins before acceptance.

At pickup the kitchen board shows a code to give the courier. At drop-off the
customer shows the separate code from the order confirmation or account history.
The courier signs into Dispatch and submits each code from
`/ui/restaurant-receipts` against the active assignment. The restaurant ledger
matches the signed receipt to the exact assignment, phase and code commitment.
Dispatch completes the trip after the ledger records drop-off. Keep the
restaurant endpoint secret stable while any issued codes are outstanding.

The routine path requires no dispatcher RPC or document review. A revoked
courier, changed route, or cancellation after accepted custody requires
operator reconciliation. The pilot uses a fixed destination and does not
collect customer addresses in checkout.

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
