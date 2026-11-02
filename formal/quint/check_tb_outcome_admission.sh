#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
spec=tb_outcome_admission.qnt
quint typecheck "$spec"
quint test "$spec"
quint run "$spec" --invariant=safety --max-samples=3000 --max-steps=25 --seed=1
quint verify "$spec" --invariant=safety --max-steps=8

for witness in noAppendBeforeCursor noOutOfOrder noIndependentSink; do
  out=$(quint run "$spec" --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "PASS: $witness is reachable"
  else
    echo "$out" >&2
    echo "ERROR: missing nonvacuity witness $witness" >&2
    exit 1
  fi
done

for mutation in unsafeDuplicateStep unsafeBodyStep unsafeCursorStep unsafeForgetStep; do
  out=$(quint run "$spec" --step="$mutation" --invariant=safety --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "PASS: intended invariant violation for $mutation"
  else
    echo "$out" >&2
    echo "ERROR: mutation $mutation did not produce an invariant violation" >&2
    exit 1
  fi
done
