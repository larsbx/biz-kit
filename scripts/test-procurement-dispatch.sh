#!/usr/bin/env bash
# Runs only against explicitly opted-in disposable loopback test databases.
set -euo pipefail

case "$#:${1:-}" in
  0:) packaged_only=false ;;
  1:--packaged-only) packaged_only=true ;;
  *) echo "Usage: $0 [--packaged-only]" >&2; exit 2 ;;
esac

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
gate=procurement-dispatch
if "$packaged_only"; then
  gate=procurement-dispatch-packaged
  umask 077
fi
receipts="$root/.artifacts/$gate/$revision"
mkdir -p "$receipts"
if "$packaged_only"; then
  command -v flock >/dev/null || { echo "Required tool missing: flock" >&2; exit 1; }
  exec 9>"$receipts/run.lock"
  flock -n 9 || { echo "Packaged acceptance is already running at $revision" >&2; exit 1; }
fi
# A failed preflight must clear any earlier success for this gate.
rm -f "$receipts/result.json" "$receipts/packaged/receipt.json" \
  "$receipts/procurement-release.tar.gz" "$receipts/dispatch-acceptance-release.tar.gz" \
  "$receipts/artifact.sha256"
printf '%s\n' "$revision" > "$receipts/revision.txt"
for tool in python3 elixir mix rustc cargo openssl createdb dropdb pg_dump pg_restore tar sha256sum; do
  command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done
python3 - "$packaged_only" <<'PY'
import os
import sys
from urllib.parse import urlsplit

if os.environ.get("PROCUREMENT_DISPATCH_ACCEPTANCE") != "disposable-local-postgres":
    raise SystemExit("Set PROCUREMENT_DISPATCH_ACCEPTANCE=disposable-local-postgres for disposable test databases only")
loopback = {"localhost", "127.0.0.1", "::1"}
if os.environ.get("EVENTSTORE_HOST", "localhost") not in loopback:
    raise SystemExit("The canonical ledger test database must be on loopback")
if sys.argv[1] == "true":
    if os.environ.get("EVENTSTORE_HOST", "127.0.0.1") != "127.0.0.1":
        raise SystemExit("Packaged Dispatch acceptance requires IPv4 loopback PostgreSQL")
    if not all(os.environ.get(name) for name in ("EVENTSTORE_USERNAME", "EVENTSTORE_PASSWORD")):
        raise SystemExit("The disposable PostgreSQL role and password are required")
    raise SystemExit(0)

url = urlsplit(os.environ.get("DATABASE_URL", ""))
if (url.scheme not in {"ecto", "postgres", "postgresql"} or url.hostname not in loopback
        or url.path != "/dispatch_test" or url.port not in {None, 5432}
        or url.query or url.fragment):
    raise SystemExit("DATABASE_URL must name the disposable loopback dispatch_test database on port 5432")
if os.environ.get("MIX_TEST_PARTITION"):
    raise SystemExit("Run the acceptance against the named test databases without a partition override")
PY

if [ -n "${SOURCE_REVISION:-}" ]; then test "$SOURCE_REVISION" = "$revision"; fi
paths=(apps config native mix.exs mix.lock tests/procurement_mvp \
  scripts/test-procurement-dispatch.sh .github/workflows/procurement-dispatch.yml)
if "$packaged_only"; then
  paths+=(.tool-versions .github/workflows/procurement-dispatch-packaged.yml)
fi
git -C "$root" diff --quiet HEAD -- "${paths[@]}"
test -z "$(git -C "$root" ls-files --others --exclude-standard -- "${paths[@]}")"
test -s "$root/tests/procurement_mvp/test_dispatch_release_controls.py"
control=test_dispatch_release_controls.py
if "$packaged_only"; then control=test_packaged_dispatch_controls.py; fi
python3 -m unittest discover -s "$root/tests/procurement_mvp" -p "$control" -v \
  2>&1 | tee "$receipts/runner-controls.log"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
# Test-only composition: Dispatch does not acquire a production dependency on
# ProcurementHost, RestaurantHost or a second business ledger.
for app in coop_substrate biz_kit_cluster task_core order_core restaurant_core \
  fulfillment_core agent_core agent_ops_store group_buy_core inventory_core \
  federation_core federation_service commerce_core barter_core dispatch_core procurement_host dispatch \
  biz_kit_identity biz_kit_extension; do
  cp -R "$root/apps/$app" "$stage/apps/"
done
cp "$root/config/config.exs" "$stage/config/"
cp "$root/mix.exs" "$root/mix.lock" "$stage/"
cp -R "$root/native" "$stage/"
printf '%s\n' "$revision" > "$stage/SOURCE_REVISION"
printf '[inputs: []]\n' > "$stage/.formatter.exs"
cd "$stage"
{ elixir --version; python3 --version; pg_dump --version; pg_restore --version; openssl version; rustc --version; } \
  > "$receipts/toolchain.txt"
mix deps.get --check-locked 2>&1 | tee "$receipts/dependencies.log"
# Compile-time config reads these variables. Neither archive should retain the
# runner's database credentials. Each release receives its own URL at runtime.
without_database=(env -u DATABASE_URL -u EVENTSTORE_USERNAME -u EVENTSTORE_PASSWORD
  -u EVENTSTORE_HOST -u EVENTSTORE_PORT -u MIX_TEST_PARTITION)
if "$packaged_only"; then
  cp "$root/config/dispatch_acceptance_runtime.exs" "$stage/config/"
  "${without_database[@]}" mix release dispatch_acceptance 2>&1 | tee "$receipts/dispatch-release-build.log"
  dispatch_release=_build/test/rel/dispatch_acceptance
  mkdir "$dispatch_release/acceptance"
  cp "$root/tests/procurement_mvp/dispatch_peer.exs" "$dispatch_release/acceptance/"
  cp SOURCE_REVISION "$dispatch_release/"
  tar -C _build/test/rel -czf "$receipts/dispatch-acceptance-release.tar.gz" dispatch_acceptance
else
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
# Packaged execution has its own receipt. Never sweep a prior packaged build
# or its logs into this source-worker result just because the directory exists.
source_files = ("revision.txt", "toolchain.txt", "runner-controls.log", "dependencies.log",
                "compile.log", "signer-count.log", "dispatch.log", "worker.log", "contracts.log")
logs = {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in source_files}
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
fi

# Both gates execute the same production-profile Procurement release.
cp "$root/config/procurement_runtime.exs" "$stage/config/"
MIX_ENV=prod mix deps.get --check-locked 2>&1 | tee "$receipts/release-dependencies.log"
MIX_ENV=prod "${without_database[@]}" mix release procurement --overwrite 2>&1 | tee "$receipts/release-build.log"
printf '%s\n' "$revision" > _build/prod/rel/procurement/SOURCE_REVISION
tar -C _build/prod/rel -czf "$receipts/procurement-release.tar.gz" procurement
if "$packaged_only"; then
  (cd "$receipts"; sha256sum procurement-release.tar.gz dispatch-acceptance-release.tar.gz > artifact.sha256)
  PROCUREMENT_RELEASE_ACCEPTANCE=disposable-local-postgres \
    python3 "$root/tests/procurement_mvp/packaged_dispatch_acceptance.py" \
      --procurement-archive "$receipts/procurement-release.tar.gz" \
      --dispatch-archive "$receipts/dispatch-acceptance-release.tar.gz" \
      --revision "$revision" --receipts "$receipts/packaged" \
    2>&1 | tee "$receipts/packaged-acceptance.log"
  test -s "$receipts/packaged/receipt.json"
  exit 0
fi

sha256sum "$receipts/procurement-release.tar.gz" > "$receipts/artifact.sha256"

# Both opt-ins apply only after the disposable database preflight above. The
# Python driver owns the packaged host process and its separate test databases.
PROCUREMENT_RELEASE_ACCEPTANCE=disposable-local-postgres \
PROCUREMENT_DISPATCH_ACCEPTANCE=disposable-local-postgres \
python3 "$root/tests/procurement_mvp/dispatch_release_acceptance.py" \
  --archive "$receipts/procurement-release.tar.gz" --revision "$revision" \
  --receipts "$receipts/packaged" --dispatch-project "$stage/apps/dispatch" \
  2>&1 | tee "$receipts/packaged-acceptance.log"
test -s "$receipts/result.json"
test -s "$receipts/packaged/receipt.json"
echo "Source Dispatch worker acceptance: $receipts/result.json"
echo "Packaged procurement with separate source Dispatch: $receipts/packaged/receipt.json"
echo "Disposable fixture; packaged Dispatch and graphical courier acceptance remain separate."
