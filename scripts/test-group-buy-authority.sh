#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
cp -R "$root/apps/coop_substrate" "$root/apps/biz_kit_cluster" "$root/apps/task_core" "$root/apps/group_buy_core" "$root/apps/inventory_core" "$stage/apps/"
cp "$root/config/config.exs" "$stage/config/config.exs"
cp "$root/mix.lock" "$stage/mix.lock"
printf 'defmodule GroupBuyAuthorityHarness.MixProject do\n use Mix.Project\n def project, do: [apps_path: "apps", deps: []]\nend\n' > "$stage/mix.exs"
printf '[inputs: []]\n' > "$stage/.formatter.exs"
cd "$stage"
mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors
mix format --check-formatted apps/coop_substrate/lib/coop_substrate/group_buys.ex apps/coop_substrate/lib/coop_substrate/group_buys/cipher.ex apps/coop_substrate/lib/coop_substrate/group_buys/escrow_admission.ex apps/coop_substrate/lib/coop_substrate/group_buys/stock.ex apps/coop_substrate/test/group_buy_authority_test.exs apps/coop_substrate/test/group_buy_escrow_admission_test.exs
cd apps/coop_substrate
mix test test/log_test.exs test/envelope_test.exs test/coop_substrate/log/serializer_test.exs test/group_buy_authority_test.exs test/group_buy_escrow_admission_test.exs --warnings-as-errors
