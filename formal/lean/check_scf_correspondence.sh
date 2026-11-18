#!/usr/bin/env bash
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"

# Pin the bytes actually loaded by the observation runner, not only the ref.
check_blob() {
  local path=$1 expected=$2 actual
  actual=$(git hash-object -- "$path")
  if [[ $actual != "$expected" ]]; then
    printf 'SCF source changed: %s (expected %s, got %s)\n' "$path" "$expected" "$actual" >&2
    exit 1
  fi
}

source_dir=apps/scf_core/lib/scf_core
check_blob "$source_dir/chart.ex" 3d2090183387cd83db88fb2b53062c7b80b7aac9
check_blob "$source_dir/entry.ex" 765f244e718cf72240e72047af9ae29bbc2c8a34
check_blob "$source_dir/ledger.ex" 1ef284eb8f4774daf5b0182c295d5fdab5381382
check_blob "$source_dir/statements.ex" 86b024910166bbc1e5dc3e6da61e3bbcde0d5916

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export SCF_LEAN_OBSERVATIONS="$scratch/ScfObservations.lean"
printf 'import BizKitScf\nopen BizKitScf\n' > "$SCF_LEAN_OBSERVATIONS"

elixir -r "$source_dir/chart.ex" -r "$source_dir/entry.ex" -r "$source_dir/ledger.ex" \
  -r apps/scf_core/test/test_helper.exs -r apps/scf_core/test/source_correspondence_test.exs \
  -e 'ExUnit.configure(seed: 0)'

observations=$(grep -c '^example :' "$SCF_LEAN_OBSERVATIONS")
test "$observations" -ge 20
cd formal/lean
lake build BizKitScf
lake env lean "$SCF_LEAN_OBSERVATIONS"
printf 'Checked %s SCF observations at %s\n' "$observations" "$(git rev-parse HEAD)"
