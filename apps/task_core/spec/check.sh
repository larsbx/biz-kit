#!/usr/bin/env bash
# Model-check every Quint spec in this directory, or in $SPECS_DIR (a host's
# own specs), or those named as arguments, locally and in CI. For each spec:
#   1. the `safety` invariant holds in sampled runs;
#   2. every witness (`val no…`) is violated, i.e. each state it names is
#      reachable, so `safety` cannot pass vacuously;
#   3. `safety` holds exhaustively up to a bounded depth (Apalache).
# A spec without a step relation is a library, typechecked here and checked
# through the specs that import it.
# Tunables: SAMPLES (default 3000), DEPTH (default 5).
set -euo pipefail
cd "${SPECS_DIR:-$(dirname "$0")}"

check() {
  local spec=$1
  echo "== $spec"
  quint typecheck "$spec"
  # A library (no step relation) is checked through the specs importing it.
  if ! grep -qE '^\s*action step\b' "$spec"; then echo "library: checked by its importers"; return; fi

  quint run "$spec" --invariant=safety --max-samples="${SAMPLES:-3000}" --max-steps=25

  # Witnesses run with a fixed seed: deterministic, and each is found within
  # ~100 samples, far inside the budget.
  for witness in $(grep -oE '^\s*val no[A-Za-z]+' "$spec" | awk '{print $2}'); do
    out=$(quint run "$spec" --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
    if grep -q '\[violation\]' <<<"$out"; then
      echo "witness $witness: reachable"
    else
      echo "witness $witness: NOT reached, so safety may hold vacuously" >&2
      echo "$out" >&2
      exit 1
    fi
  done

  quint verify "$spec" --invariant=safety --max-steps="${DEPTH:-5}"
}

if [ $# -gt 0 ]; then specs=("$@"); else specs=(*.qnt); fi
for spec in "${specs[@]}"; do check "$spec"; done
