#!/usr/bin/env bash
# Temporal authority policy matrix for a blocked E3 activation (issue #296).
# Every cell is asserted: `holds` needs a completed bounded verification, and
# `violated` needs a model counterexample. No policy is selected here.
set -euo pipefail
cd "$(dirname "$0")"
spec=dispatch_e3_authority.qnt
steps=10
echo 'Authority/time model: 2 conflicting assignments, clock 0..4, bound 1; atomic commits.'
quint typecheck "$spec"
quint test "$spec"

holds() {
  local step=$1 invariant=$2 result=0 output
  quint run "$spec" --step="$step" --invariant="$invariant" \
    --max-samples=3000 --max-steps=25 --seed=1 --verbosity=1
  output=$(quint verify "$spec" --step="$step" --invariant="$invariant" \
    --max-steps="$steps" --verbosity=1 2>&1) || result=$?
  # A clean server startup is not evidence that the bounded checker completed.
  if [[ "$result" != 0 || "$output" != *'[ok]'* || "$output" != *'No violation found'* ]]; then
    echo "$output" >&2
    echo "ERROR: expected $step to satisfy $invariant through $steps steps" >&2
    exit 1
  fi
  echo "Holds $step/$invariant (bounded, $steps steps)"
}
violated() {
  local step=$1 invariant=$2 result=0 output
  output=$(quint run "$spec" --step="$step" --invariant="$invariant" \
    --max-samples=10000 --max-steps=25 --seed=1 --verbosity=1 2>&1) || result=$?
  if [[ "$result" != 1 || "$output" != *'[violation]'* ]]; then
    echo "$output" >&2
    echo "ERROR: expected an invariant counterexample for $step/$invariant" >&2
    exit 1
  fi
  echo "Refuted $step/$invariant (model counterexample only)"
}

for step in step boundedStep recheckStep commitStep; do
  holds "$step" baseline
  violated "$step" neverWaitedCommit
done
violated step commitAuthority
violated step boundedStaleness
holds boundedStep boundedStaleness
holds boundedStep boundedClockLapse
violated boundedStep commitAuthority
holds recheckStep recheckAuthority
violated recheckStep commitAuthority
holds commitStep commitAuthority
violated commitStep boundedStaleness
violated unlockedStep revocationOrdered
