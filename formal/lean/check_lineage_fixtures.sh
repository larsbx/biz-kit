#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

fixture=../../apps/coop_substrate/test/fixtures/commercial_lineage.tsv
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
lake env lean --run CommercialLineageFixtures.lean > "$scratch"
diff -u "$fixture" "$scratch"
