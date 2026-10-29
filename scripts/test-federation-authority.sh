#!/usr/bin/env bash
set -euo pipefail
# A disposable PostgreSQL test database is REQUIRED. mix test recreates it.
# Never run this harness against an installation's business database.
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
for app in coop_substrate biz_kit_cluster task_core agent_core agent_ops_store \
  group_buy_core inventory_core federation_core federation_service; do
  cp -R "$root/apps/$app" "$stage/apps/"
done
cp "$root/mix.lock" "$stage/mix.lock"
cat > "$stage/mix.exs" <<'EOF'
defmodule FederationAuthorityHarness.MixProject do
  use Mix.Project
  def project, do: [apps_path: "apps", deps: []]
end
EOF
cat > "$stage/config/config.exs" <<'EOF'
import Config
import_config "../apps/coop_substrate/config/config.exs"
EOF
export MIX_ENV=test
cd "$stage"
mix deps.get --check-locked
mix compile --warnings-as-errors
mix format --check-formatted \
  apps/coop_substrate/lib/coop_substrate/federation_authority.ex \
  apps/coop_substrate/lib/coop_substrate/federation_fence.ex \
  apps/coop_substrate/lib/coop_substrate/log.ex \
  apps/coop_substrate/lib/coop_substrate/projections/membership.ex \
  apps/coop_substrate/lib/coop_substrate/protocol/type_registry.ex \
  apps/coop_substrate/lib/coop_substrate/protocol/validity.ex \
  apps/coop_substrate/test/federation_authority_test.exs
cd apps/coop_substrate
mix test test/federation_authority_test.exs test/log_test.exs test/role_key_test.exs
