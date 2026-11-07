#!/usr/bin/env bash
# Run from apps/dispatch AFTER the ordinary integration suite passes.
# These are current-behavior negative controls, not accepted global policy.
set -euo pipefail

test_file=test/dispatch/operations/board_driver_exclusivity_test.exs
control_log_dir=$(mktemp -d)
trap 'rm -rf "$control_log_dir"' EXIT

check_control() {
  local flag=$1 tag=$2 message=$3 result=0
  env "$flag=1" MIX_ENV=test mix test --include integration --only "$tag" "$test_file" \
    >"$control_log_dir/$tag.log" 2>&1 || result=$?
  cat "$control_log_dir/$tag.log"
  # A compiler/startup error must not masquerade as a refuted invariant.
  if [[ "$result" != 2 ]]; then
    echo "Expected an ExUnit assertion failure for $tag; received exit $result" >&2
    return 1
  fi
  python3 - "$control_log_dir/$tag.log" "$message" <<'PY'
import pathlib, re, sys
log = pathlib.Path(sys.argv[1]).read_text()
assert re.search(r"\b1 failure\b", log), "expected exactly one selected failing test"
assert sys.argv[2] in log, "expected the specific exclusivity assertion, not an unrelated failure"
PY
  echo "Confirmed current-behavior refutation: $tag"
}

check_control DISPATCH_ASSERT_GLOBAL_DRIVER_EXCLUSIVITY global_driver_boundary \
  "distinct trip must wait on the index conflict"
check_control DISPATCH_ASSERT_BOUND_DRIVER_PROFILE operator_profile_boundary \
  "proposed acceptance: another participant's role must not relax exclusivity"
