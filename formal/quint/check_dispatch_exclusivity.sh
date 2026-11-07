#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
spec=dispatch_exclusivity.qnt
quint typecheck "$spec"
quint test "$spec"
quint run "$spec" --invariant=safety --max-samples=3000 --max-steps=25 --seed=1 --verbosity=1
quint verify "$spec" --invariant=safety --max-steps=8

# The first protocol omits commit-time global admission; the second uses only
# the current partial-index scope. Demand actual invariant violations.
for control in 'snapshotStep safety' 'tenantStep globalSafety'; do
  read -r step invariant <<< "$control"
  result=0
  output=$(quint run "$spec" --step="$step" --invariant="$invariant" \
    --max-samples=10000 --max-steps=25 --seed=1 --verbosity=1 2>&1) || result=$?
  if [[ "$result" != 1 || "$output" != *'[violation]'* ]]; then
    echo "$output" >&2
    echo "ERROR: expected an invariant counterexample for $step/$invariant" >&2
    exit 1
  fi
  echo "Refuted $step/$invariant (model counterexample only)"
done

# Additional E3 scenarios use five dynamically planned assignment IDs and two Users.
bash check_dispatch_e3.sh
