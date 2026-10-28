#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

for spec in eatsbot_marketing_candidate.qnt eatsbot_delivery_candidate.qnt; do
  echo "Checking $spec"
  quint typecheck "$spec"
  quint run "$spec" --invariant=safety --max-samples=1500 --max-steps=15 --seed=1
  quint verify "$spec" --invariant=safety --max-steps=7
done

for pair in "eatsbot_marketing_candidate.qnt noCreditWitness" \
            "eatsbot_delivery_candidate.qnt noDeliveryWitness" \
            "eatsbot_delivery_candidate.qnt noHeldWitness"; do
  read -r spec witness <<< "$pair"
  out=$(quint run "$spec" --invariant="$witness" --max-samples=10000 --max-steps=20 --seed=1 2>&1 || true)
  if grep -q '\[violation\]' <<< "$out"; then
    echo "Witness $witness reachable in $spec"
  else
    echo "$out" >&2
    echo "ERROR: failed to reach $witness in $spec" >&2
    exit 1
  fi
done

quint typecheck eatsbot_marketing_bug.qnt
out=$(quint run eatsbot_marketing_bug.qnt --invariant=safety --max-samples=10000 --max-steps=15 --seed=1 2>&1 || true)
if grep -q '\[violation\]' <<< "$out"; then
  echo "Negative control: unverified marketing credit violates safety"
else
  echo "$out" >&2
  echo "ERROR: negative control not refuted" >&2
  exit 1
fi
