#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
spec=commercial_source_fence.qnt

quint typecheck "$spec"
quint run "$spec" --main=commercial_source_fence --invariant=safety \
  --max-samples=3000 --max-steps=15 --seed=1
quint verify "$spec" --main=commercial_source_fence --invariant=safety \
  --max-steps=5

for witness in noAcceptedWitness noRefusalWitness; do
  out=$(quint run "$spec" --main=commercial_source_fence \
    --invariant="$witness" --max-samples=10000 --max-steps=20 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "PASS: $witness is reachable"
  else
    echo "$out" >&2
    echo "ERROR: missing reachability witness $witness" >&2
    exit 1
  fi
done

# The identical abstract transition without the source/consent guard must
# produce a real failing safety trace. Typecheck errors do not count.
out=$(quint run "$spec" --main=commercial_source_fence_control \
  --invariant=safety --max-samples=10000 --max-steps=20 --seed=1 2>&1 || true)
if grep -q '\[violation\]' <<<"$out"; then
  echo "PASS: unsafe source-binding/consent control violates safety"
else
  echo "$out" >&2
  echo "ERROR: unsafe source-binding/consent model not refuted" >&2
  exit 1
fi
