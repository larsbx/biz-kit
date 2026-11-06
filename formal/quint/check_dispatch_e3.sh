#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
spec=dispatch_e3.qnt
echo 'E3 finite model: 5 assignment IDs, 2 Users, 2 tenants, 4 participants; atomic commits, trusted identities.'
quint typecheck "$spec"
quint test "$spec"
quint run "$spec" --invariant=safety --max-samples=3000 --max-steps=25 --seed=1 --verbosity=1
verification_result=0
verification_output=$(quint verify "$spec" --invariant=safety --max-steps=8 --verbosity=1 2>&1) || verification_result=$?
echo "$verification_output"
# A clean server startup is not evidence that the bounded checker completed.
if [[ "$verification_result" != 0 || "$verification_output" != *'[ok]'* || "$verification_output" != *'No violation found'* ]]; then
  echo 'ERROR: expected a completed E3 bounded verification result (maximum 8 steps)' >&2
  exit 1
fi
for control in 'xxOnlyStep globalSafety' 'tenantOnlyStep globalSafety' 'preflightOnlyStep globalSafety' 'mutableStep immutableSnapshots' 'earlyReleaseStep globalSafety'; do
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
