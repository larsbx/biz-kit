#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
fixture=../../apps/inventory_core/test/fixtures/proof_bank_locations.tsv.gz
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
lake env lean --run InventoryFixtures.lean > "$scratch"
python3 - "$scratch" "$fixture" <<'PY'
import gzip, pathlib, sys
actual = pathlib.Path(sys.argv[1]).read_bytes()
expected = gzip.decompress(pathlib.Path(sys.argv[2]).read_bytes())
if actual != expected:
    raise SystemExit("Inventory fixtures differ from Lean evaluation; regenerate and review")
print(f"Lean fixture equality: {len(actual.splitlines())} command outcomes")
PY
