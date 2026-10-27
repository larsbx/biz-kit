#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Pin the Quint CLI in CI. Type check and simulate the safe model before the
# bounded exhaustive Apalache proof. Fail rather than tolerate tool errors.
quint typecheck event_cursor.qnt
quint run event_cursor.qnt --invariant=safety --max-samples=3000 --max-steps=25 --seed=1
quint verify event_cursor.qnt --invariant=safety --max-steps=6

# Both witnesses must be reachable. A proof that never reaches a staged state
# could be vacuous; this is an intentional bounded nonvacuity check.
for witness in noOutOfOrderEffect noStagedButNotAcknowledged; do
  out=$(quint run event_cursor.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "witness $witness: reachable"
  else
    echo "$out" >&2
    echo "ERROR: expected reachable $witness witness" >&2
    exit 1
  fi
done

# Deliberately unsafe cursor-first model must be refuted. A compile/tool
# failure is NOT an accepted counterexample: typecheck independently first.
quint typecheck cursor_first_bug.qnt
out=$(quint run cursor_first_bug.qnt --invariant=safety --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
if ! grep -q '\[violation\]' <<<"$out"; then
  echo "$out" >&2
  echo "ERROR: Quint did not refute cursor-first checkpointing" >&2
  exit 1
fi
echo "negative control: cursor-first violation observed"
