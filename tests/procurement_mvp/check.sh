#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
python3 tests/procurement_mvp/model.py --output "$tmp/cases.tsv"
mkdir "$tmp/ebin"
kernel=apps/commerce_core/lib/commerce_core/merchant_pilot
elixirc --warnings-as-errors -o "$tmp/ebin" "$kernel/sourcing_bounty.ex" "$kernel/workflow.ex"
PROCUREMENT_CONFORMANCE_TSV="$tmp/cases.tsv" elixir -pa "$tmp/ebin" tests/procurement_mvp/run.exs
sha256sum "$kernel/sourcing_bounty.ex" "$kernel/workflow.ex" "$tmp/cases.tsv"
