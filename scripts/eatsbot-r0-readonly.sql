-- Eatsbot R0: what production holds, as counts only (decommission checklist §3).
--
-- Run by the owner against the production database, e.g.
--   fly postgres connect -a <eatsbot-db-app>   then   \i eatsbot-r0-readonly.sql
-- or with psql and the production DATABASE_URL.
--
-- Read-only and aggregate-only: one READ ONLY transaction that ends in
-- ROLLBACK, no row is ever selected, so no customer data leaves the
-- database. Tables a schema lacks are skipped, so it runs against both the
-- `main` schema (no orders, no marketing) and the `dev` schema.

\set ON_ERROR_STOP on
\pset footer off
BEGIN TRANSACTION READ ONLY;

\echo '== 1. Which schema production runs (latest applied migration) =='
\echo '   20261023014323 = dev (orders), 20260923000410 = dev (marketing); neither = main'
SELECT max(version) AS latest_migration,
       bool_or(version = 20261023014323) AS has_orders_migration,
       bool_or(version = 20260923000410) AS has_marketing_migration
FROM schema_migrations;

SELECT to_regclass('public.deliveries') IS NOT NULL AS has_deliveries,
       to_regclass('public.tokens') IS NOT NULL AS has_tokens,
       to_regclass('public.telegram_bot') IS NOT NULL AS has_telegram,
       to_regclass('public.users') IS NOT NULL AS has_users,
       to_regclass('public.carts') IS NOT NULL AS has_carts,
       to_regclass('public.orders') IS NOT NULL AS has_orders,
       to_regclass('public.marketing_subscribers') IS NOT NULL AS has_subscribers,
       to_regclass('public.marketing_visits') IS NOT NULL AS has_visits,
       to_regclass('public.marketing_promotions') IS NOT NULL AS has_promotions
\gset

\if :has_deliveries
\echo '== 2. Deliveries: every non-Stale state is an open obligation or awaits archiving =='
\echo '   open = Init, In_Preparation, Ready_To_Pickup, In_Delivery, Delivery_With_Problems'
SELECT state, count(*) AS deliveries, min(inserted_at) AS oldest, max(updated_at) AS last_change
FROM deliveries GROUP BY state ORDER BY state;
\endif

\if :has_orders
\echo '== 3. Orders by state (completed, cancelled and failed are terminal) =='
SELECT state, count(*) AS orders, min(inserted_at) AS oldest, max(updated_at) AS last_change
FROM orders GROUP BY state ORDER BY state;
\echo '   amounts on non-terminal orders, by currency (minor units as stored)'
SELECT currency, count(*) AS orders, sum(total) AS total
FROM orders WHERE state::text NOT IN ('completed', 'cancelled', 'failed')
GROUP BY currency ORDER BY currency;
\endif

\if :has_visits
\echo '== 4. Marketing visits: unredeemed redemptions and commissions =='
SELECT status, count(*) AS visits, sum(commission) AS commission
FROM marketing_visits GROUP BY status ORDER BY status;
\endif

\if :has_promotions
SELECT count(*) FILTER (WHERE ends_at IS NULL OR ends_at > now()) AS promotions_running,
       count(*) AS promotions
FROM marketing_promotions;
\endif

\if :has_subscribers
\echo '== 5. Marketing consent: opt-outs must be kept with the archive (never elevated) =='
SELECT channel, status, count(*) AS subscribers
FROM marketing_subscribers GROUP BY channel, status ORDER BY channel, status;
\endif

\if :has_telegram
\echo '== 6. Telegram delivery-update subscriptions (dropped with the bot, D2) =='
SELECT status, count(*) AS subscriptions FROM telegram_bot GROUP BY status ORDER BY status;
\endif

\if :has_tokens
\echo '== 7. Sign-in tokens still valid (revoke or let expire at shutdown) =='
SELECT purpose, count(*) AS unexpired, max(expires_at) AS latest_expiry
FROM tokens WHERE expires_at > now() GROUP BY purpose ORDER BY purpose;
\endif

\if :has_users
\echo '== 8. Accounts (no account migrates, D1/D4) =='
SELECT count(*) AS users, count(*) FILTER (WHERE admin) AS admins FROM users;
\endif

\if :has_carts
SELECT status, count(*) AS carts FROM carts GROUP BY status ORDER BY status;
\endif

\echo '== 9. Archive sizing: rows per table =='
SELECT relname AS table_name, n_live_tup AS approx_rows
FROM pg_stat_user_tables ORDER BY relname;

ROLLBACK;
