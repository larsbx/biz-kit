#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
spec=commercial_lineage.qnt

quint typecheck "$spec"
quint run "$spec" --main=commercial_lineage --invariant=provenanceSafety \
  --max-samples=3000 --max-steps=15 --seed=1
quint verify "$spec" --main=commercial_lineage --invariant=provenanceSafety \
  --max-steps=6

for witness in noAssignedWitness noAssignBackWitness noClosureWitness; do
  out=$(quint run "$spec" --main=commercial_lineage \
    --invariant="$witness" --max-samples=10000 --max-steps=20 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "PASS: reached $witness"
  else
    echo "$out" >&2
    echo "ERROR: missing lineage nonvacuity witness $witness" >&2
    exit 1
  fi
done

# Must show an actual counterexample after assignment-back reclassifies
# an already assigned original as fresh. A tool error does not qualify.
out=$(quint run "$spec" --main=commercial_lineage_control \
  --invariant=provenanceSafety --max-samples=10000 --max-steps=20 --seed=1 2>&1 || true)
if grep -q '\[violation\]' <<<"$out"; then
  echo "PASS: unsafe reassignment reclassification violates provenance"
else
  echo "$out" >&2
  echo "ERROR: unsafe control did not violate provenance"
  exit 1
fi
