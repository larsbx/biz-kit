#!/usr/bin/env bash
# One command for the stack d-patch's end-to-end tests run against
# (docs/architecture/2026-10-21-end-to-end-stack.md): fresh databases, the
# e2e fixtures, then dispatch on :4000 and SpruceGoose's /auth on 127.0.0.1:4001.
#
#   scripts/e2e-stack.sh            prepare, then run in the foreground
#   scripts/e2e-stack.sh --prepare  prepare only
#   scripts/e2e-stack.sh fixture …  priv/repo/e2e.exs against the running stack
#
# Needs PostgreSQL with PostGIS on localhost (PGPASSWORD, default "postgres").
# Writes $E2E_STATE_DIR/stack.json (default .e2e/), which the tests read.

set -euo pipefail
cd "$(dirname "$0")/.."

export MIX_ENV=dev
export PGPASSWORD="${PGPASSWORD:-postgres}"
export EVENTSTORE_PASSWORD="${EVENTSTORE_PASSWORD:-$PGPASSWORD}"
export DATABASE_URL="${DATABASE_URL:-ecto://postgres:${PGPASSWORD}@localhost:5432/dispatch_e2e}"

# The fixtures during a run, with the stack's own databases.
if [ "${1:-}" = "fixture" ]; then
  shift
  cd apps/dispatch && exec mix run priv/repo/e2e.exs "$@"
fi

state="$(mkdir -p "${E2E_STATE_DIR:-.e2e}" && cd "${E2E_STATE_DIR:-.e2e}" && pwd)"
stack="$state/stack.json"

prepare() {
  mix deps.get >/dev/null
  (cd apps/coop_substrate && mix event_store.drop --quiet -e CoopSubstrate.EventStore &&
    mix event_store.create --quiet && mix event_store.init --quiet)
  # --force-drop: a server stopped a moment ago may still hold connections.
  (cd apps/spruce_goose && mix ecto.drop --quiet --force-drop && mix ecto.create --quiet && mix ecto.migrate --quiet)
  (cd apps/dispatch && mix ecto.drop --quiet --force-drop && mix ash.setup --quiet)
  # `mix phx.server` below starts every umbrella app; eatsbot needs its database.
  (cd apps/eatsbot && mix ecto.drop --quiet --force-drop && mix ash.setup --quiet)
  (cd apps/dispatch && mix run priv/repo/e2e.exs seed "$stack")
}

field() { elixir -e "IO.write(JSON.decode!(File.read!(\"$stack\"))[\"$1\"] |> then(&if(is_binary(&1), do: &1, else: JSON.encode!(&1))))"; }

# Not `[ … ] || prepare`: set -e does not apply inside an || list, and a
# failed step must stop the script.
if [ "${1:-}" != "--serve-only" ]; then prepare; fi
if [ "${1:-}" = "--prepare" ]; then exit 0; fi

# Dispatch accepts biz-kit sessions; /auth signs people in through the
# development provider, one provider name per seeded person.
export TOKEN_VERIFIER_ADAPTER=Dispatch.Identity.Tokens.BizKitSession
export BIZKIT_DEVELOPMENT_SIGN_IN="$(field development_sign_in)"
export BIZKIT_IDENTITY_BINDINGS="$(field bindings)"
export BIZKIT_NATIVE_REDIRECT_URIS="com.dispatch.driver:/oauth2redirect"
export SPRUCE_GOOSE_MCP_ENABLED=true
# Every person signs in from 127.0.0.1 within a minute (config/runtime.exs).
export SPRUCE_GOOSE_SIGN_IN_LIMIT="${SPRUCE_GOOSE_SIGN_IN_LIMIT:-600}"
export MCP_PORT="${MCP_PORT:-4001}"
# Where a browser reaches /auth, and where the development provider sends it
# back: the Android emulator reaches the host as 10.0.2.2.
export SPRUCE_GOOSE_PUBLIC_URL="${SPRUCE_GOOSE_PUBLIC_URL:-http://127.0.0.1:${MCP_PORT}}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(printf 'e2e-only-%.0s' {1..8})}"
# Required by SpruceGoose's MCP surface, which these tests do not use.
export SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS="00000000-0000-4000-8000-000000000001=00000000-0000-4000-8000-000000000002"

exec mix phx.server
