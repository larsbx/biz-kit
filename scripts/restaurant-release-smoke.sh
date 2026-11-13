#!/usr/bin/env bash
# Build the production restaurant release, migrate, boot it, check it serves
# the storefront and pairs a board, enroll both devices, then complete a pickup order on
# its own ledger (scripts/restaurant_release_smoke.exs). Locally and in CI; see
# docs/deploy.md.
#
# Needs PostgreSQL reachable as $PGUSER/$PGPASSWORD (default postgres/postgres)
# on localhost; it creates the database it names. Secrets are throwaway.
set -euo pipefail
cd "$(dirname "$0")/.."

export MIX_ENV=prod RELEASE_COOKIE=smoke
export EVENTSTORE_USERNAME="${PGUSER:-postgres}" EVENTSTORE_PASSWORD="${PGPASSWORD:-postgres}"
export EVENTSTORE_DATABASE=restaurant_smoke_eventstore
seed() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
export RESTAURANT_PORT="${RESTAURANT_PORT:-4070}"
export RESTAURANT_PUBLIC_BASE_URL="http://localhost:$RESTAURANT_PORT"
export RESTAURANT_SECRET_KEY_BASE="$(head -c 64 /dev/urandom | base64 | tr -d '\n')"
export RESTAURANT_DEVICE_SEED_STOREFRONT="$(seed)" RESTAURANT_DEVICE_SEED_BOARD_1="$(seed)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pairing=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
chapter="smoke-$(date +%s)-$RANDOM"
cat > "$work/restaurant.json" <<JSON
{
  "chapter": "$chapter",
  "merchant": "shop",
  "currency": "USD",
  "jurisdiction": "US-MI",
  "menu": [{"id": "margherita", "name": "Margherita", "sku": "MARG", "price_minor": 1250}],
  "storefront": {"device_id": "storefront", "key_id": "k-store"},
  "boards": {"board-1": {"device_id": "board-1", "key_id": "k-board",
             "pairing_sha256": "$(printf '%s' "$pairing" | sha256sum | cut -d' ' -f1)"}}
}
JSON
export RESTAURANT_CONFIG_FILE="$work/restaurant.json"

mix release restaurant --overwrite
release=_build/prod/rel/restaurant/bin/restaurant

# Twice: migrating must be safe to repeat before every start.
for _ in 1 2; do "$release" eval "RestaurantHost.ReleaseTasks.migrate()"; done

# The only bootstrap is a self-signed governance declaration, never a device grant.
export RESTAURANT_SMOKE_BOOTSTRAP="$work/governance.event"
HARNESS_KEYS_DIR="$work/keys" "$release" eval "Code.eval_file(\"$PWD/scripts/restaurant_enrollment_smoke_setup.exs\")"
# The server does not receive HARNESS_KEYS_DIR or the governance seed.
env -u HARNESS_KEYS_DIR "$release" daemon
trap '"$release" stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

url="http://localhost:$RESTAURANT_PORT"
for _ in $(seq 1 60); do curl -fs -o /dev/null "$url/" && break; sleep 1; done
curl -fs "$url/" | grep -q "Margherita" || { echo "the storefront did not come up" >&2; exit 1; }

# A wrong secret is refused; the right one pairs the board and redirects to it.
test "$(curl -s -o /dev/null -w '%{http_code}' "$url/board/pair/board-1/wrong")" = 403
test "$(curl -s -o /dev/null -w '%{http_code}' "$url/board/pair/board-1/$pairing")" = 302

"$release" rpc 'env = System.fetch_env!("RESTAURANT_SMOKE_BOOTSTRAP") |> File.read!() |> :erlang.binary_to_term([:safe]); {:ok, _} = CoopSubstrate.Log.append(env)'
for device in storefront board-1; do
  # A separate release VM has neither device seeds nor a running appender.
  HARNESS_KEYS_DIR="$work/keys" env -u RESTAURANT_DEVICE_SEED_STOREFRONT -u RESTAURANT_DEVICE_SEED_BOARD_1 \
    "$release" eval "nil = Process.whereis(CoopSubstrate.Log); RestaurantHost.ReleaseTasks.grant([\"$device\", \"--chapter\", \"$chapter\", \"--merchant\", \"shop\", \"--server\", \"$url\", \"--yes\"])"
done

cat > "$work/menu.json" <<JSON
{
  "merchant_id": "shop",
  "expected_revision": 0,
  "currency": "USD",
  "items": [{"id": "margherita", "name": "Margherita special", "sku": "MARG",
             "price_minor": 1250, "discount_minor": 250}]
}
JSON
HARNESS_KEYS_DIR="$work/keys" env -u RESTAURANT_DEVICE_SEED_STOREFRONT -u RESTAURANT_DEVICE_SEED_BOARD_1 \
  "$release" eval "nil = Process.whereis(CoopSubstrate.Log); RestaurantHost.ReleaseTasks.manage([\"publish-menu\", \"$work/menu.json\", \"--chapter\", \"$chapter\", \"--server\", \"$url\"])"
curl -fs "$url/" | grep -q "Margherita special"

out=$("$release" rpc "Code.eval_file(\"$PWD/scripts/restaurant_release_smoke.exs\")")
echo "$out"
grep -q "^SMOKE OK" <<<"$out"
