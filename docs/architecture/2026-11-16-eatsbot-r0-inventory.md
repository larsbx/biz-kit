# Eatsbot R0 inventory

Date: 2026-11-16. Status: **source-side inventory; the running host not
observed.** R0 of the [decommission checklist](2026-11-07-eatsbot-decommission.md).
Read from biz-kit `main` `fa72bed6`, and from `larsbx/eatsbot` `dev`
`a552153a` and `main` `e1c7fdc` for the old infrastructure.

## Where Eatsbot runs

Eatsbot runs **through biz-kit**, not on the old Fly infrastructure (owner,
2026-11-16). On biz-kit, `deploy-adder-ws.yml` wakes the `adder-ws` host, whose
`biz-kit-stack.service` runs [`scripts/e2e-stack.sh`](../../scripts/e2e-stack.sh)
([deploy/adder-ws-cd](../../deploy/adder-ws-cd/README.md)). That script runs
the whole umbrella with `MIX_ENV=dev mix phx.server`, so the legacy
`apps/eatsbot` copy serves on `127.0.0.1:4100`, alongside Dispatch,
SpruceGoose and the task host. `restaurant_host` (`127.0.0.1:4070`) is in the
same umbrella, but the script sets no `RESTAURANT_CONFIG_FILE`, so the
rebuilt eatsbot is not configured there.

Two facts follow, and both change R4–R6:

1. **Legacy Eatsbot's data does not survive a restart.** Before each start,
   `e2e-stack.sh` runs `ecto.drop --force-drop && ash.setup` on
   `apps/eatsbot` (database `eatsbot_dev`), as it does for the other apps.
   Every deploy and every service restart therefore starts legacy Eatsbot
   empty. D1 ("start empty, migrate nothing") holds by construction: there is
   no durable legacy history to migrate. What is open at any moment is only
   what was written since the last start, and it is lost at the next one. If
   real customers are being served there, take an archive before any restart
   (below); otherwise there is nothing to keep.
2. **The legacy writer is fenced by stopping it, not by triggers.**
   `CoopSubstrate.WriterFence` installs refusing triggers in the legacy
   database, but the next stack start drops and recreates that database, which
   erases them. On this host, the R5 switch is to stop serving `apps/eatsbot`:
   remove it (and its `ecto.drop`/`ash.setup` line) from what `e2e-stack.sh`
   starts, and configure `restaurant_host` in its place. R6 then removes
   `apps/eatsbot*` and the `eatsbot` release from the umbrella.

The legacy endpoint runs in dev mode: code reloader, debug error pages and a
committed `secret_key_base` (`apps/eatsbot/config/dev.exs`). It binds to
loopback only, so exposure depends on what proxies it on `adder-ws`.

## Schema and personal data (`apps/eatsbot`)

Biz-kit's copy carries the full `dev` schema, including `orders`,
`order_lines`, `order_state_changes` (2026-10-23) and the `marketing_*` tables
(2026-09-23). Personal data:

| Table | Personal data |
| --- | --- |
| `deliveries` | recipient `to_name`, `to_phone`, `to_address`, `to_notes`; pickup, drop-off and live courier coordinates; bearer `private_auth_key`, `public_auth_key` |
| `orders` | `contact` |
| `marketing_subscribers` | `address` (Telegram chat), consent `status` |
| `users` | `email`, `admin` |
| `tokens` | sign-in token `jti`, `subject`, `expires_at` |
| `telegram_bot` | delivery-update subscriptions |

None of it enters the ledger (D1). The bearer delivery keys are never honoured
elsewhere. Open deliveries are the states with outgoing transitions: `Init`,
`In_Preparation`, `Ready_To_Pickup`, `In_Delivery`, `Delivery_With_Problems`.

Kafka has no consumer: no config sets `:kafka_driver`, so `EatsbotCore.Kafka`
uses its `Noop` driver. There is no job queue.

## Surfaces legacy Eatsbot serves

| Surface | Disposition | Switch action |
| --- | --- | --- |
| `/gql` GraphQL, including `/gql/playground` | Dropped (D3) | Stop serving `apps/eatsbot` |
| Telegram bot (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK`) | Dropped (D2) | If a webhook is registered, `deleteWebhook`, then revoke the token |
| `/deliveries`, `/map` LiveView | Replaced by Dispatch (fixed-route pilot) | Finish open deliveries first |
| `/auth`, `/admin` (AshAdmin, `ADMIN_API_KEY`) | Not migrated (D1, D4) | Stop serving; unset the secrets |

## What only the owner can answer

1. Is `adder-ws`'s Eatsbot serving real customers, or is it the e2e stack its
   name says? If real: what proxies `127.0.0.1:4100` to them, and is a Telegram
   webhook registered for it?
2. If real, before the next restart, run
   [`scripts/eatsbot-r0-readonly.sql`](../../scripts/eatsbot-r0-readonly.sql)
   on `adder-ws`: `psql -d eatsbot_dev -f scripts/eatsbot-r0-readonly.sql`.
   It runs in one `READ ONLY` transaction that ends in `ROLLBACK` and returns
   counts only: open deliveries and orders by state, unredeemed visits and
   commissions, consent, Telegram subscriptions, unexpired tokens, rows per
   table. Then `pg_dump eatsbot_dev` to the restricted archive (§3) if
   anything must be kept.

## Old Fly infrastructure (retired)

`larsbx/eatsbot` still holds a Fly configuration (app `eatsbot`, region `scl`,
`fly.toml` from 2025-02-18) and workflows (`fly-deploy.yml` on push to `main`,
`fly-reset.yml`, `promote-release.yml`). None of these workflows has ever run
in that repository, and `eatsbot.fly.dev` did not answer through this
environment's gateway on 2026-11-16 12:01 UTC. To retire it: delete the Fly
app and its database if they still exist, revoke the `FLY_API_TOKEN` and
`FLY_API_TOKEN_SSH` repository secrets, and disable those workflows, so that a
push to `larsbx/eatsbot` `main` can never deploy a second, forgotten writer.
