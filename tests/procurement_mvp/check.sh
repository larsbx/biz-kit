#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 tests/procurement_mvp/model.py --output "$tmp/cases.tsv"
mkdir "$tmp/ebin"
elixirc --warnings-as-errors -o "$tmp/ebin" apps/commerce_core/lib/commerce_core/merchant_pilot/workflow.ex
PROCUREMENT_CONFORMANCE_TSV="$tmp/cases.tsv" elixir -pa "$tmp/ebin" tests/procurement_mvp/run.exs
sha256sum apps/commerce_core/lib/commerce_core/merchant_pilot/workflow.ex "$tmp/cases.tsv"
