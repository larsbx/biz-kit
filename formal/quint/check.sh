#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

bash check_tb_outcome_admission.sh

# Version-pinned Quint 0.32.0 is installed by GitHub Actions. The safe
# models must typecheck, pass sampled safety, and pass bounded Apalache.
for spec in event_cursor.qnt lease_fencing.qnt effect_bundles.qnt cursor_transaction.qnt dispatch_trip.qnt dispatch_idempotency.qnt; do
  echo "Checking safety: $spec"
  quint typecheck "$spec"
  quint run "$spec" --invariant=safety --max-samples=3000 --max-steps=25 --seed=1
  # No-op event 2 and its processed receipt need a longer trace than the
  # simple one-event cursor/lease cases. Keep the search finite and explicit.
  depth=6
  if [[ "$spec" == "effect_bundles.qnt" || "$spec" == "cursor_transaction.qnt" ]]; then
    depth=10
  fi
  quint verify "$spec" --invariant=safety --max-steps="$depth"
done

# Explicit nonvacuity: safe models must reach meaningful intermediate states.
for witness in noOutOfOrderEffect noStagedButNotAcknowledged; do
  out=$(quint run event_cursor.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "event_cursor: $witness reachable"
  else
    echo "$out" >&2
    echo "ERROR: expected reachable $witness witness" >&2
    exit 1
  fi
done

for witness in noClaimWitness noLaunchWitness; do
  out=$(quint run lease_fencing.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "lease_fencing: $witness reachable"
  else
    echo "$out" >&2
    echo "ERROR: expected reachable $witness witness" >&2
    exit 1
  fi
done

for witness in noPartialBundle noNoopReceipt; do
  out=$(quint run effect_bundles.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "effect_bundles: $witness reachable"
  else
    echo "$out" >&2
    echo "ERROR: expected reachable $witness witness" >&2
    exit 1
  fi
done

for witness in noPartialTxWitness noFullCommitWitness noNoopCommitWitness; do
  out=$(quint run cursor_transaction.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "cursor_transaction: $witness reachable"
  else
    echo "$out" >&2
    echo "ERROR: expected reachable $witness witness" >&2
    exit 1
  fi
done

# Dispatch nonvacuity: a passing invariant over only the initial state is
# insufficient. Exercise both terminal outcomes, a refused attempt, exact
# replay, and rejection of a different request with the same key.
for witness in noCompletedWitness noCancelledWitness noRefusalWitness noScheduledActiveWitness noUnscheduledActiveWitness; do
  out=$(quint run dispatch_trip.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "dispatch_trip: $witness reachable"
  else
    echo "$out" >&2
    echo "ERROR: Dispatch witness $witness not reached" >&2
    exit 1
  fi
done

for witness in noReplayWitness noConflictWitness; do
  out=$(quint run dispatch_idempotency.qnt --invariant="$witness" --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "dispatch_idempotency: $witness reachable"
  else
    echo "$out" >&2
    echo "ERROR: Idempotency witness $witness not reached" >&2
    exit 1
  fi
done

# Deliberately broken protocols must be REFUTED: first typecheck, then demand
# a real invariant violation. Never accept a parse/typecheck/runtime crash as
# a successful safety counterexample.
for spec in cursor_first_bug.qnt lease_crash_bug.qnt bundle_partial_bug.qnt dispatch_terminal_bug.qnt dispatch_idempotency_bug.qnt; do
  quint typecheck "$spec"
  out=$(quint run "$spec" --invariant=safety --max-samples=10000 --max-steps=25 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<<"$out"; then
    echo "negative control $spec: unsafe trace observed"
  else
    echo "$out" >&2
    echo "ERROR: negative control $spec was not refuted" >&2
    exit 1
  fi
done
