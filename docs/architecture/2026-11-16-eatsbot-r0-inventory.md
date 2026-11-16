# Eatsbot R0 inventory: what the source shows, what production must answer

Date: 2026-11-16. Status: **source-side inventory; production not observed.**
R0 of the [decommission checklist](2026-11-07-eatsbot-decommission.md).
Read from `larsbx/eatsbot` at `dev` `a552153a` (2026-10-31) and `main`
`e1c7fdc` (2025-11-25, v1.0.42), and from that repository's Actions history.
Nothing here was read from Fly or the production database.

## Findings

1. **The production revision is unknown, and it is probably not `dev`.**
   `.github/workflows/fly-deploy.yml` deploys on push to **`main`**, and
   `promote-release.yml` only tags `main`; nothing moves `dev` to production.
   Neither workflow has ever run in `larsbx/eatsbot` (all its workflows were
   created 2025-11-25), while `eatsbot/fly.toml` was generated 2025-02-18.
   Production was therefore deployed by hand or from an earlier repository.
   Biz-kit's statement that "Fly deploys it from `larsbx/eatsbot` `dev`"
   ([deploy](../deploy.md)) is unverified. `dev` and `main` differ in 165 files.
2. **The production app did not answer.** `https://eatsbot.fly.dev/`
   (app `eatsbot`, region `scl`, scales to zero) refused connection through
   this environment's gateway on 2026-11-16 12:01 UTC ("host allowed, gateway
   could not connect"). A stopped Fly machine normally wakes on request, so the
   app may be deleted or without public IPs. Not conclusive from here.
3. **If production runs `main`, it never had orders or marketing.** The
   `orders`, `order_lines`, `order_state_changes` and all `marketing_*` tables
   come from migrations only on `dev` (2026-09-23, 2026-10-23). `main`'s
   schema: catalog tables, `carts`, `cart_lines`, `deliveries`,
   `delivery_state_changes`, `users`, `tokens`, `telegram_bot`. Its open
   obligations are then only unfinished deliveries; there are no orders,
   refunds, promotions, redemptions or commissions to drain.
4. **Kafka has no production consumer.** `config/prod.exs` points at
   `localhost:9092–9094`, the Kafka extension is loaded only in `dev.exs` behind
   `ENABLE_KAFKA`, and no config sets `:kafka_driver`, so `EatsbotCore.Kafka`
   uses its `Noop` driver (`produce/3` returns `:ok`). Topics
   `eatsbot-deliveries` and `eatsbot-telegram` are never written in production.
5. **No job queue.** No Oban or other durable queue on either branch; nothing
   to drain beyond the Telegram webhook.

## Surfaces production serves (from `main`'s router and config)

| Surface | Disposition (D1–D6) | Cutover action |
| --- | --- | --- |
| `/gql` GraphQL, including `/gql/playground` | Dropped (D3) | Consumers are external: find them in Fly request logs; tell them. The playground is reachable in production. |
| Telegram bot (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK`), `telegram_bot` subscriptions | Dropped (D2) | `deleteWebhook`, then revoke the token with BotFather. |
| `/deliveries`, `/map` LiveView (admin) | Replaced by Dispatch | Finish open deliveries first (§ below). |
| `/auth` (password and magic link, `MAILGUN_*` mail) | Not migrated (D1, D4) | Revoke unexpired `tokens`; stop Mailgun sending. |
| `/admin` AshAdmin (`ADMIN_API_KEY` basic auth) | Dropped | Rotate `ADMIN_API_KEY` away at shutdown. |
| Prometheus extension | Conditional | Only if a scraper is found in R0. |

Other secrets in `runtime.exs`: `DATABASE_URL`, `SECRET_KEY_BASE`,
`TOKEN_SIGNING_SECRET`, `GEOCODING_TOKEN`, `PUBLIC_URL`, `OTLP_ENDPOINT`,
`DNS_CLUSTER_QUERY`. Each is revoked or rotated after retention, not reused.

## Personal data held (`main` schema)

| Table | Personal data |
| --- | --- |
| `deliveries` | recipient `to_name`, `to_phone`, `to_address`, `to_notes`; pickup, drop-off and live courier coordinates; bearer `private_auth_key` and `public_auth_key` |
| `users` | `email`, `admin` |
| `tokens` | sign-in token `jti`, `subject`, `expires_at` |
| `telegram_bot` | delivery-update subscriptions |

On `dev` add: `orders.contact`, `marketing_subscribers.address` (Telegram
chat), visits and commissions. None of it enters the ledger (D1). The bearer
delivery keys are never migrated or honoured anywhere; they expire with the
archive. The archive keeps opt-outs.

Open deliveries on `main` are the states with outgoing transitions: `Init`,
`In_Preparation`, `Ready_To_Pickup`, `In_Delivery`, `Delivery_With_Problems`.
`Delivery_Done` and `Delivery_Aborted` await the stale cleaner; the three
`Stale_*` states are terminal.

## What only the owner can answer

Run, with production credentials:

1. `fly status -a eatsbot` and `fly releases -a eatsbot`: does the app exist,
   and which image and revision is live? Compare with `main` `e1c7fdc` and
   `dev` `a552153a`.
2. [`scripts/eatsbot-r0-readonly.sql`](../../scripts/eatsbot-r0-readonly.sql)
   against the production database. It runs in one `READ ONLY` transaction
   that ends in `ROLLBACK` and returns counts only, never rows. It reports
   which schema is live (latest migration), open deliveries and orders by
   state, unredeemed visits and commissions, consent by status, Telegram
   subscriptions, unexpired tokens, accounts and rows per table for archive
   sizing. It was checked against databases shaped like both schemas.
3. Fly request logs for `/gql` and the Telegram webhook over a recent window:
   who still calls them.

If (1) shows no app, R4 and R5 reduce to archiving the database (if it still
exists) and revoking credentials: there is no live writer to fence. If it
shows `main`, the drain is unfinished deliveries only. If it shows `dev`, the
full §3 obligation list applies, and (2) sizes it.
