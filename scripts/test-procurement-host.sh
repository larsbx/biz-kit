#!/usr/bin/env bash
# Destructive to the dedicated coop_substrate_eventstore_test database only.
set -euo pipefail
export PROCUREMENT_ENABLED=false
root=$(cd "$(dirname "$0")/.." && pwd)
receipts=${PROCUREMENT_RECEIPTS:-"$root/.artifacts/procurement-host"}
mkdir -p "$receipts"
receipts=$(cd "$receipts" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
for app in coop_substrate biz_kit_cluster task_core order_core restaurant_core agent_core \
  agent_ops_store group_buy_core inventory_core federation_core federation_service \
  commerce_core procurement_host; do
  cp -R "$root/apps/$app" "$stage/apps/"
done
cp "$root/config/config.exs" "$root/config/procurement_runtime.exs" "$stage/config/"
cp "$root/mix.exs" "$root/mix.lock" "$stage/"
if [ -d "$root/native" ]; then cp -R "$root/native" "$stage/"; fi
printf '[inputs: []]\n' > "$stage/.formatter.exs"
git -C "$root" rev-parse HEAD | tee "$receipts/revision.txt"
python3 "$root/tests/procurement_mvp/admission_reference.py" | tee "$receipts/reference.json"
elixir --version | tee "$receipts/toolchain.txt"
bash "$root/tests/procurement_mvp/check.sh" 2>&1 | tee "$receipts/kernel.log"
cd "$stage"
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tee "$receipts/compile.log"
(cd apps/coop_substrate; mix test test/procurement_test.exs test/log_test.exs test/envelope_test.exs --warnings-as-errors) \
  2>&1 | tee "$receipts/ledger-tests.log"
(cd apps/procurement_host; mix test --warnings-as-errors) 2>&1 | tee "$receipts/http-tests.log"
# Build the real release definition with its own runtime config, not a fake host.
MIX_ENV=prod mix release procurement --overwrite 2>&1 | tee "$receipts/release-build.log"
tar -C _build/prod/rel -czf "$receipts/procurement-release.tar.gz" procurement
sha256sum "$receipts/procurement-release.tar.gz" > "$receipts/artifact.sha256"
echo 'Scoped tests and artifact build passed; deployed TLS/browser/restore acceptance is still separate.'
