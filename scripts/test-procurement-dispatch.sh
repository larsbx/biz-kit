#!/usr/bin/env bash
# Runs only against explicitly opted-in disposable loopback test databases.
set -euo pipefail

export MIX_ENV=test
export PROCUREMENT_ENABLED=false
export BIZKIT_BUNDLED_TEST_LOCALE=true
export PYTHONDONTWRITEBYTECODE=1
# Fixtures enable one synthetic route after Dispatch starts. Never inherit an
# operator's automatic polling configuration into this test process.
export RESTAURANT_DISPATCH_AUTOMATED=false
export PROCUREMENT_DISPATCH_AUTOMATED=false

root=$(cd "$(dirname "$0")/.." && pwd)
revision=$(git -C "$root" rev-parse HEAD)
receipts="$root/.artifacts/procurement-dispatch/$revision"
mkdir -p "$receipts"
# Even a rejected rerun must not leave an older success as its apparent result.
rm -f "$receipts/result.json"
printf '%s\n' "$revision" > "$receipts/revision.txt"
for tool in python3 elixir mix; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
python3 - <<'PY'
import os
from urllib.parse import urlsplit

if os.environ.get("PROCUREMENT_DISPATCH_ACCEPTANCE") != "disposable-local-postgres":
    raise SystemExit("Set PROCUREMENT_DISPATCH_ACCEPTANCE=disposable-local-postgres for disposable test databases only")
loopback = {"localhost", "127.0.0.1", "::1"}
if os.environ.get("EVENTSTORE_HOST", "localhost") not in loopback:
    raise SystemExit("The canonical ledger test database must be on loopback")
url = urlsplit(os.environ.get("DATABASE_URL", ""))
if (url.scheme not in {"ecto", "postgres", "postgresql"} or url.hostname not in loopback
        or url.path != "/dispatch_test" or url.port not in {None, 5432}
        or url.query or url.fragment):
    raise SystemExit("DATABASE_URL must name the disposable loopback dispatch_test database on port 5432")
if os.environ.get("MIX_TEST_PARTITION"):
    raise SystemExit("Run the acceptance against the named test databases without a partition override")
PY

if [ -n "${SOURCE_REVISION:-}" ]; then test "$SOURCE_REVISION" = "$revision"; fi
paths=(apps config native mix.exs mix.lock scripts/test-procurement-dispatch.sh .github/workflows/procurement-dispatch.yml)
git -C "$root" diff --quiet HEAD -- "${paths[@]}"
test -z "$(git -C "$root" ls-files --others --exclude-standard -- "${paths[@]}")"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
# Test-only composition: Dispatch does not acquire a production dependency on
# ProcurementHost, RestaurantHost or a second business ledger.
for app in coop_substrate biz_kit_cluster task_core order_core restaurant_core \
  fulfillment_core agent_core agent_ops_store group_buy_core inventory_core \
  federation_core federation_service commerce_core dispatch_core procurement_host dispatch \
  biz_kit_identity biz_kit_extension; do
  cp -R "$root/apps/$app" "$stage/apps/"
done
cp "$root/config/config.exs" "$stage/config/"
cp "$root/mix.exs" "$root/mix.lock" "$stage/"
cp -R "$root/native" "$stage/"
printf '[inputs: []]\n' > "$stage/.formatter.exs"
cd "$stage"
{ elixir --version; python3 --version; } > "$receipts/toolchain.txt"
mix deps.get --check-locked 2>&1 | tee "$receipts/dependencies.log"
mix compile --warnings-as-errors 2>&1 | tee "$receipts/compile.log"

# The existing alias recreates only coop_substrate_eventstore_test and verifies
# #353's two-signer rejection against the actual appender before the worker run.
(cd apps/coop_substrate; mix test test/procurement_test.exs test/procurement_dispatch_policy_test.exs --warnings-as-errors) \
  2>&1 | tee "$receipts/signer-count.log"
(cd apps/dispatch; mix ash.setup --quiet; mix test --include integration --warnings-as-errors) \
  2>&1 | tee "$receipts/dispatch.log"
(cd apps/dispatch; mix test \
  --include integration --warnings-as-errors integration_test/procurement_delivery_test.exs) \
  2>&1 | tee "$receipts/worker.log"
(cd apps/dispatch; mix openapi.check; mix ash_postgres.generate_migrations --check) \
  2>&1 | tee "$receipts/contracts.log"

python3 - "$receipts" "$revision" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

out = Path(sys.argv[1])
for name in ("signer-count.log", "dispatch.log", "worker.log"):
    log = (out / name).read_text()
    if (not re.search(r"\b[1-9][0-9]* tests?, 0 failures\b", log)
            or re.search(r"\b[1-9][0-9]* invalid\b", log)):
        raise SystemExit(f"Missing nonempty passing test summary: {name}")
logs = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(out.iterdir()) if p.is_file() and p.name != "result.json"}
result = {
    "revision": sys.argv[2],
    "execution_kind": "source-dispatch-worker-postgresql",
    "fixture": "synthetic-disposable-loopback",
    "trust": "unsigned-runner-observation",
    "checks": {"signer_count_rejection": True, "dispatch_regressions": True,
               "real_worker_assignment_and_custody": True, "machine_contract": True},
    "files_sha256": logs,
    "packaged_dispatch_worker": False,
    "live_delivery": False,
}
(out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
PY
echo "Real Dispatch worker, assignment and courier-session acceptance: $receipts"
echo "Synthetic fixture; packaged procurement HTTPS/Tauri checks remain separately reported."
