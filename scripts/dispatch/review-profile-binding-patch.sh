#!/usr/bin/env bash
# Review experiment only: red baseline -> patched acceptance -> restored source.
# Requires the existing disposable Dispatch PostgreSQL setup and compiled deps.
set -euo pipefail
if [[ $# != 1 || ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Usage: bash scripts/dispatch/review-profile-binding-patch.sh REVIEWED_SHA" >&2
  exit 1
fi
reviewed_sha=$1
root=$(git rev-parse --show-toplevel)
cd "$root"
[[ $(git rev-parse HEAD) == "$reviewed_sha" ]] || { echo 'Reviewed revision mismatch' >&2; exit 1; }
[[ -z $(git status --porcelain --untracked-files=all) ]] || { echo 'Review requires a clean checkout' >&2; exit 1; }
target=apps/dispatch/lib/dispatch/fleet/changes/derive_operator_exclusivity.ex
patch=docs/proof-bank/dispatch/PROPOSED_BIND_OPERATOR_PROFILE.patch
scratch=$(mktemp -d)
cp "$target" "$scratch/original.ex"
patched=0
cleanup() {
  result=$?
  trap - EXIT
  set +e
  if [[ "$patched" == 1 ]]; then
    cp "$scratch/original.ex" "$root/$target"
    restored=$?
    if [[ "$restored" == 0 ]]; then
      (cd "$root/apps/dispatch" && MIX_ENV=test mix compile --force) >"$scratch/restore.log" 2>&1
      restored=$?
    fi
    if [[ "$restored" != 0 ]] || ! cmp -s "$scratch/original.ex" "$root/$target"; then
      cat "$scratch/restore.log" 2>/dev/null >&2
      echo 'ERROR: baseline source/build restoration failed' >&2
      result=1
    else
      echo 'Restored baseline source and rebuilt Dispatch'
    fi
  fi
  rm -rf "$scratch"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
printf 'Review experiment base: %s\n' "$reviewed_sha"
sha256sum "$target" "$patch"

test_candidate() {
  (cd apps/dispatch && DISPATCH_ASSERT_GLOBAL_DRIVER_EXCLUSIVITY=0 \
    DISPATCH_ASSERT_BOUND_DRIVER_PROFILE=1 MIX_ENV=test \
    mix test --include integration \
      test/dispatch/operations/board_driver_exclusivity_test.exs --trace)
}

result=0
test_candidate >"$scratch/baseline.log" 2>&1 || result=$?
cat "$scratch/baseline.log"
[[ "$result" == 2 ]] || { echo 'Expected baseline ExUnit refusal of the proposed invariant' >&2; exit 1; }
python3 - "$scratch/baseline.log" <<'PY'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r"\b14 tests, 1 failure\b", log), "expected 14 cases and one baseline assertion failure"
assert "proposed acceptance: another participant's role must not relax exclusivity" in log
assert not re.search(r"\b[1-9][0-9]* (?:excluded|skipped)\b", log), "all cases must execute"
PY

[[ $(git rev-parse HEAD) == "$reviewed_sha" ]]
[[ -z $(git status --porcelain --untracked-files=all) ]]
cmp -s "$scratch/original.ex" "$target"
git apply --check "$patch"
# Register restoration before any write, including a partially failed apply.
patched=1
git apply "$patch"
sha256sum "$target"
# This result refers to the explicitly patched source, never to an unchanged HEAD.
result=0
test_candidate >"$scratch/candidate.log" 2>&1 || result=$?
cat "$scratch/candidate.log"
[[ "$result" == 0 ]] || { echo 'Candidate patch did not pass acceptance' >&2; exit 1; }
python3 - "$scratch/candidate.log" <<'PY'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r"\b14 tests, 0 failures\b", log), "expected all 14 candidate cases to pass"
assert not re.search(r"\b[1-9][0-9]* (?:excluded|skipped)\b", log), "all cases must execute"
PY
# Explicit restoration and clean-source check before claiming experiment success.
cp "$scratch/original.ex" "$target"
(cd apps/dispatch && MIX_ENV=test mix compile --force) >"$scratch/restore.log" 2>&1
cmp -s "$scratch/original.ex" "$target"
[[ $(git rev-parse HEAD) == "$reviewed_sha" ]]
[[ -z $(git status --porcelain --untracked-files=all) ]]
patched=0
printf 'Candidate profile-binding experiment passed; baseline %s restored and rebuilt\n' "$reviewed_sha"
