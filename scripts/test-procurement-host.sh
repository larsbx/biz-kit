#!/usr/bin/env bash
# Destructive to coop_substrate_eventstore_test and fresh synthetic databases.
# Explicit opt-in and loopback PostgreSQL are required; never use production.
set -euo pipefail
export PROCUREMENT_ENABLED=false
export PYTHONDONTWRITEBYTECODE=1
root=$(cd "$(dirname "$0")/.." && pwd)
receipts=${PROCUREMENT_RECEIPTS:-"$root/.artifacts/procurement-host"}
mkdir -p "$receipts"
receipts=$(cd "$receipts" && pwd)
# A failed rerun must never publish a previous success receipt or artifact.
rm -f "$receipts/release/receipt.json" "$receipts/procurement-release.tar.gz" "$receipts/artifact.sha256"
for tool in python3 elixir mix openssl createdb dropdb pg_dump pg_restore; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
python3 - "$root" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1] + "/tests/procurement_mvp")
from release_acceptance import database_environment
database_environment(dict(os.environ))
PY
revision=$(git -C "$root" rev-parse HEAD)
if [ -n "${SOURCE_REVISION:-}" ]; then test "$SOURCE_REVISION" = "$revision"; fi
# Receipts bind committed source, not an unrecorded edited working tree.
paths=(apps config mix.exs mix.lock native scripts/test-procurement-host.sh tests/procurement_mvp proofs/procurement_mvp .github/workflows/procurement-mvp-host.yml)
git -C "$root" diff --quiet HEAD -- "${paths[@]}"
test -z "$(git -C "$root" ls-files --others --exclude-standard -- "${paths[@]}")"
printf '%s\n' "$revision" | tee "$receipts/revision.txt"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
# Include the ledger's test-only dependencies without changing the release roots.
for app in coop_substrate biz_kit_cluster task_core order_core restaurant_core fulfillment_core agent_core \
  agent_ops_store group_buy_core inventory_core federation_core federation_service \
  commerce_core barter_core dispatch_core procurement_host; do
  cp -R "$root/apps/$app" "$stage/apps/"
done
cp "$root/config/config.exs" "$root/config/procurement_runtime.exs" "$stage/config/"
cp "$root/mix.exs" "$root/mix.lock" "$stage/"
if [ -d "$root/native" ]; then cp -R "$root/native" "$stage/"; fi
printf '[inputs: []]\n' > "$stage/.formatter.exs"
python3 -m unittest discover -s "$root/tests/procurement_mvp" -p test_release_acceptance.py -v \
  2>&1 | tee "$receipts/runner-controls.log"
python3 "$root/tests/procurement_mvp/admission_reference.py" | tee "$receipts/reference.json"
{ elixir --version; python3 --version; pg_dump --version; pg_restore --version; } | tee "$receipts/toolchain.txt"
bash "$root/tests/procurement_mvp/check.sh" 2>&1 | tee "$receipts/kernel.log"
cd "$stage"
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tee "$receipts/compile.log"
(cd apps/coop_substrate; mix test test/procurement_test.exs test/procurement_contract_test.exs test/procurement_dispatch_policy_test.exs test/log_test.exs test/envelope_test.exs --warnings-as-errors) \
  2>&1 | tee "$receipts/ledger-tests.log"
(cd apps/procurement_host; mix test --warnings-as-errors) 2>&1 | tee "$receipts/http-tests.log"
MIX_ENV=prod mix deps.get --check-locked
MIX_ENV=prod mix release procurement --overwrite 2>&1 | tee "$receipts/release-build.log"
printf '%s\n' "$revision" > _build/prod/rel/procurement/SOURCE_REVISION
tar -C _build/prod/rel -czf "$receipts/procurement-release.tar.gz" procurement
sha256sum "$receipts/procurement-release.tar.gz" > "$receipts/artifact.sha256"
# The runner unpacks and executes this archive with its bundled ERTS, not Mix.
python3 "$root/tests/procurement_mvp/release_acceptance.py" \
  --archive "$receipts/procurement-release.tar.gz" --revision "$revision" \
  --receipts "$receipts/release" 2>&1 | tee "$receipts/release-acceptance.log"
echo 'Scoped tests, packaged HTTPS lifecycle, cold restart, revocation and synthetic SQL restore passed.'
echo 'Target-host deployment and graphical-browser acceptance remain separate.'
