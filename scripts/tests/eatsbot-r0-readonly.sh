#!/usr/bin/env bash
# Requires PostgreSQL and libpq connection settings (PGHOST, PGUSER, etc.).
# The test creates and drops its own database, populated only with fixtures.
set -euo pipefail
cd "$(dirname "$0")/../.."

database="eatsbot_r0_test_${BASHPID}_${RANDOM}"
createdb --maintenance-db=postgres "$database"
trap 'dropdb --maintenance-db=postgres "$database"' EXIT

psql -X -q -v ON_ERROR_STOP=1 -d "$database" <<'SQL'
-- The type and currency check from the retired Ash Money v5 migration
-- (20250304111339_install_ash_money_v5_extension.exs).
CREATE TYPE money_with_currency AS (currency_code varchar, amount numeric);

CREATE FUNCTION money_sum_state_function(state money_with_currency, money money_with_currency)
RETURNS money_with_currency
IMMUTABLE STRICT LANGUAGE plpgsql AS $$
BEGIN
  IF (state).currency_code <> (money).currency_code THEN
    RAISE EXCEPTION 'Incompatible currency codes' USING ERRCODE = '22033';
  END IF;
  RETURN ROW((state).currency_code, (state).amount + (money).amount);
END;
$$;

CREATE AGGREGATE sum(money_with_currency) (
  sfunc = money_sum_state_function,
  stype = money_with_currency
);

CREATE TABLE schema_migrations (version bigint);
INSERT INTO schema_migrations VALUES (20260923000410);
CREATE TABLE marketing_visits (status text, commission money_with_currency);
INSERT INTO marketing_visits VALUES
  ('checked_in', NULL),
  ('redeemed', ROW('USD', 1.25)),
  ('redeemed', ROW('EUR', 4.00)),
  ('redeemed', ROW('USD', 3.00)),
  ('redeemed', NULL);

CREATE TABLE marketing_promotions (ends_at timestamptz);
INSERT INTO marketing_promotions VALUES ('infinity'), ('-infinity');
CREATE TABLE marketing_subscribers (channel text, status text);
INSERT INTO marketing_subscribers VALUES ('email', 'unsubscribed');
CREATE TABLE telegram_bot (status text);
INSERT INTO telegram_bot VALUES ('subscribed');
CREATE TABLE tokens (purpose text, expires_at timestamptz);
INSERT INTO tokens VALUES ('sign_in', 'infinity'), ('sign_in', '-infinity');
CREATE TABLE users (admin boolean);
INSERT INTO users VALUES (true), (false), (false);
CREATE TABLE carts (status text);
INSERT INTO carts VALUES ('active'), ('active');
SQL

output=$(psql -X -At -P null=NULL -d "$database" -f scripts/eatsbot-r0-readonly.sql)

# Compare the report through promotions, including the NULL commission groups.
actual=$(sed -n '/^== 4\./,/^== 5\./{ /^== /d; p; }' <<< "$output")
diff -u - <(printf '%s\n' "$actual") <<'EXPECTED'
checked_in|NULL|1|NULL
redeemed|EUR|1|(EUR,4.00)
redeemed|USD|2|(USD,4.25)
redeemed|NULL|1|NULL
1|2
EXPECTED

# Check results after the commission query and the closing rollback.
for line in 'email|unsubscribed|1' 'subscribed|1' 'sign_in|1|infinity' '3|1' 'active|2' 'ROLLBACK'; do
  if [[ $'\n'"$output"$'\n' != *$'\n'"$line"$'\n'* ]]; then
    printf 'Missing inventory result: %s\n%s\n' "$line" "$output" >&2
    exit 1
  fi
done
if [[ $'\n'"$output" != *$'\nmarketing_visits|'* ]]; then
  printf 'Missing marketing_visits in archive sizing\n%s\n' "$output" >&2
  exit 1
fi

printf 'Inventory reported EUR 4.00 and USD 4.25 separately, then completed the remaining checks.\n'
