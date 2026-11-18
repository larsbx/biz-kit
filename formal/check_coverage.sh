#!/usr/bin/env bash
# Checks every Quint artifact formal/coverage.json names: typecheck, sampled
# safety, bounded Apalache verification, a reachable non-vacuity witness and,
# where named, a negative control module that must violate the invariant.
# Lean artifacts are checked by formal/lean/check.sh (build, fresh kernel
# replay and axiom audit), which the static audit requires them to be in.
set -euo pipefail
cd "$(dirname "$0")/.."
# Extra `quint run` options, e.g. QUINT_RUN_OPTS=--backend=typescript offline.
read -r -a run_opts <<<"${QUINT_RUN_OPTS:-}"

python3 -I scripts/formal_coverage_audit.py --quint-checks |
while read -r model main control invariant witness steps; do
  echo "== $model ${main}: $invariant (witness $witness, control $control, depth $steps)"
  sel=(); [[ $main != - ]] && sel=(--main="$main")
  quint typecheck "$model"
  quint run "${run_opts[@]}" "${sel[@]}" "$model" --invariant="$invariant" --max-samples=3000 --max-steps=25 --seed=1
  quint verify "${sel[@]}" "$model" --invariant="$invariant" --max-steps="$steps"
  violated() {
    local out
    out=$(quint run "${run_opts[@]}" "$@" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
    grep -q '\[violation\]' <<<"$out"
  }
  if ! violated "${sel[@]}" "$model" --invariant="$witness"; then
    echo "ERROR: witness $witness is unreachable; $invariant may hold vacuously" >&2
    exit 1
  fi
  if [[ $control != - ]] && ! violated --main="$control" "$model" --invariant="$invariant"; then
    echo "ERROR: control $control does not violate $invariant; the guard is not what makes it hold" >&2
    exit 1
  fi
done
