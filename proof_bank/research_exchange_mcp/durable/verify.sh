#!/usr/bin/env bash
# Run from any directory with pinned Elixir/OTP, Lean, and Quint available.
set -euo pipefail

if [[ $# != 3 ]]; then
  echo "Usage: bash verify.sh LEAN_ROOT QUINT_CLI OUTPUT" >&2
  exit 2
fi

lean_root="$(realpath "$1")"
quint_cli="$(realpath "$2")"
mkdir -p "$3"
output="$(realpath "$3")"
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Commit adapter changes before recording exact-revision evidence" >&2
  exit 1
fi

if [[ -n "${EXPECTED_REVISION:-}" ]]; then
  test "$(git rev-parse HEAD)" = "$EXPECTED_REVISION"
fi

python3 -B tools/verify_core_snapshot.py --require-clean --output "$output/source.json"
{
  git rev-parse HEAD HEAD^{tree}
  elixir --version
  node --version
  node "$quint_cli" --version
  python3 --version
} | tee "$output/revision-and-tools.log"

node "$quint_cli" test durable/formal/durable.qnt --backend=typescript \
  | tee "$output/quint.log"
python3 -B durable/acceptance.py --lean-root "$lean_root" --output "$output" \
  2>&1 | tee "$output/round-trip.log"

python3 -B tools/verify_core_snapshot.py --require-clean --output "$output/source-after.json"
