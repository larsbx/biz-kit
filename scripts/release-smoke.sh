#!/usr/bin/env bash
# Build the production orchestration release, migrate, boot it, and check it
# serves the web view and admits and refuses task commands on its own ledger
# (scripts/release_smoke.exs). Locally and in CI; see docs/deploy.md.
#
# Needs PostgreSQL reachable as $PGUSER/$PGPASSWORD (default postgres/postgres)
# on localhost; it creates the databases it names. Secrets are throwaway.
set -euo pipefail
cd "$(dirname "$0")/.."

export MIX_ENV=prod RELEASE_COOKIE=smoke
pg="${PGUSER:-postgres}:${PGPASSWORD:-postgres}@localhost"
export DATABASE_URL="postgres://$pg/orchestration_smoke" DATABASE_SSL=false
export EVENTSTORE_USERNAME="${PGUSER:-postgres}" EVENTSTORE_PASSWORD="${PGPASSWORD:-postgres}"
export EVENTSTORE_DATABASE=orchestration_smoke_eventstore
secret() { head -c 48 /dev/urandom | base64 | tr -d '\n'; }
export SECRET_KEY_BASE="$(secret)$(secret)" TOKEN_SIGNING_SECRET="$(secret)" OAUTH2_SIGNING_SECRET="$(secret)"
export SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR=smoke-operator SPRUCE_GOOSE_OBAN_ENABLED=false
export SPRUCE_GOOSE_MCP_ENABLED=true MCP_PORT="${MCP_PORT:-4100}"
export SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS=00000000-0000-4000-8000-000000000001=00000000-0000-4000-8000-000000000002

mix release orchestration --overwrite
release=_build/prod/rel/orchestration/bin/orchestration

# Twice: migrating must be safe to repeat before every start.
for _ in 1 2; do "$release" eval "SpruceGoose.ReleaseTasks.migrate()"; done

"$release" daemon
trap '"$release" stop >/dev/null 2>&1 || true' EXIT

url="http://localhost:$MCP_PORT/app?chapter=c&tenant=t&project=p"
for _ in $(seq 1 60); do curl -fs -o /dev/null "$url" && break; sleep 1; done
curl -fs -o /dev/null "$url" || { echo "the web view did not come up" >&2; exit 1; }

out=$("$release" rpc "Code.eval_file(\"$PWD/scripts/release_smoke.exs\")")
echo "$out"
grep -q "^SMOKE OK" <<<"$out"
