#!/usr/bin/env bash
set -euo pipefail

# Focused GEV-01 gate. No unrelated Lean targets and no restored project oleans.
# Install the repository's pinned Lean and Apalache distributions first; put
# Lean 4.35.0 and Quint 0.32.0 on PATH and set QUINT_HOME to the Apalache home.
spatial_root=$(cd "$(dirname "$0")/.." && pwd)
spatial_artifacts=${DISPATCH_SPATIAL_ARTIFACTS:-${RUNNER_TEMP:-/tmp}/dispatch-spatial-models}
mkdir -p "$spatial_artifacts"
spatial_artifacts=$(cd "$spatial_artifacts" && pwd)
spatial_stage=$(mktemp -d "${RUNNER_TEMP:-/tmp}/bizkit-spatial-models.XXXXXX")
trap 'rm -rf "$spatial_stage"' EXIT
spatial_started=$SECONDS

spatial_lean_version=$(lean --version)
spatial_quint_version=$(quint --version)
[[ $spatial_lean_version =~ version\ 4\.35\.0[^0-9] ]]
[[ $spatial_quint_version == 0.32.0 ]]
[[ $(cat "$spatial_root/formal/lean/lean-toolchain") == leanprover/lean4:v4.35.0 ]]
: "${QUINT_HOME:?Set QUINT_HOME to the digest-verified Apalache 0.56.1 installation}"
spatial_apalache=$QUINT_HOME/apalache-dist-0.56.1/apalache/bin/apalache-mc
[[ -x $spatial_apalache ]]
[[ $("$spatial_apalache" version) == 0.56.1 ]]
{
  printf '%s\n' "$spatial_lean_version"
  lake --version
  printf 'Quint %s\nApalache 0.56.1\n' "$spatial_quint_version"
  java -version
  command -v lean lake leanchecker quint
  git -C "$spatial_root" rev-parse HEAD
} > "$spatial_artifacts/toolchains.log" 2>&1
(
  cd "$spatial_root"
  sha256sum formal/lean/BizKitDispatchSpatial.lean \
    formal/lean/CheckDispatchSpatial.lean formal/lean/lean-toolchain \
    formal/quint/dispatch_spatial.qnt formal/check_dispatch_spatial.sh
) > "$spatial_artifacts/source.sha256"
printf 'check\tseconds\tstatus\n' > "$spatial_artifacts/timing.tsv"

spatial_logged() {
  local label=$1 started=$SECONDS status
  shift
  if "$@" > "$spatial_artifacts/$label.log" 2>&1; then
    printf '%s\t%s\tPASS\n' "$label" "$((SECONDS - started))" >> "$spatial_artifacts/timing.tsv"
    printf 'PASS %s (%ss)\n' "$label" "$((SECONDS - started))"
  else
    status=$?
    printf '%s\t%s\tFAIL:%s\n' "$label" "$((SECONDS - started))" "$status" >> "$spatial_artifacts/timing.tsv"
    cat "$spatial_artifacts/$label.log" >&2
    return "$status"
  fi
}

# A fresh minimal Lake project verifies exactly this module and its audit. The
# full formal/lean/check.sh also includes this module in the global proof suite.
cp "$spatial_root/formal/lean/lean-toolchain" \
  "$spatial_root/formal/lean/BizKitDispatchSpatial.lean" \
  "$spatial_root/formal/lean/CheckDispatchSpatial.lean" "$spatial_stage/"
cat > "$spatial_stage/lakefile.toml" <<'LAKE'
name = "DispatchSpatialGate"
version = "0.1.0"
defaultTargets = ["BizKitDispatchSpatial"]
[[lean_lib]]
name = "BizKitDispatchSpatial"
LAKE
cd "$spatial_stage"
spatial_logged lean-build lake build
spatial_logged lean-kernel lake env leanchecker --fresh --verbose BizKitDispatchSpatial
spatial_logged lean-audit lake env lean CheckDispatchSpatial.lean

spatial_spec=$spatial_root/formal/quint/dispatch_spatial.qnt
spatial_logged quint-typecheck quint typecheck "$spatial_spec"
for spatial_pair in client:dispatch_spatial source:dispatch_spatial_source; do
  spatial_label=${spatial_pair%%:*}
  spatial_module=${spatial_pair#*:}
  spatial_logged "tests-$spatial_label" quint test "$spatial_spec" \
    --main="$spatial_module" --backend=typescript --seed=1
  # Sampled exploration is additional evidence, not exhaustive verification.
  spatial_logged "simulation-$spatial_label" quint run "$spatial_spec" \
    --main="$spatial_module" --backend=typescript --invariant=safety \
    --max-samples=1000 --max-steps=25 --seed=1
  # Pick an unused local endpoint rather than attach to an unrelated checker.
  spatial_port=$(python3 - <<'PY'
import socket
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    print(server.getsockname()[1])
PY
)
  spatial_logged "verify-$spatial_label" quint verify "$spatial_spec" \
    --main="$spatial_module" --invariant=safety --max-steps=6 \
    --apalache-version=0.56.1 --server-endpoint="localhost:$spatial_port"
done

for spatial_control in scope cursor work consent; do
  spatial_module=dispatch_spatial_${spatial_control}_bug
  spatial_step=${spatial_control}CounterexampleStep
  spatial_log=$spatial_artifacts/negative-$spatial_control.log
  spatial_trace=$spatial_artifacts/negative-$spatial_control.itf.json
  spatial_control_started=$SECONDS
  spatial_status=0
  # A stale trace from a prior run must never satisfy the current control.
  rm -f "$spatial_trace"
  quint run "$spatial_spec" --main="$spatial_module" --backend=typescript \
    --step="$spatial_step" --invariant=safety --max-samples=1 --max-steps=4 \
    --seed=1 --out-itf="$spatial_trace" > "$spatial_log" 2>&1 || spatial_status=$?
  if [[ $spatial_status != 1 ]] || ! grep -Fq '[violation]' "$spatial_log"; then
    cat "$spatial_log" >&2
    printf 'Expected a concrete invariant violation for %s, got status %s\n' \
      "$spatial_control" "$spatial_status" >&2
    exit 1
  fi
  # Validate the intended bad outcome in the produced trace as well as Quint's
  # violation status. A parse failure, timeout, unrelated error or empty model
  # is never accepted as a successful negative control.
  python3 - "$spatial_control" "$spatial_trace" <<'PY'
import json
import sys

control, path = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    trace = json.load(stream)
assert trace["#meta"]["status"] == "violation", trace
states = trace["states"]
assert len(states) >= 2, trace

def last_value(suffix):
    return next(value for key, value in states[-1].items() if key.endswith("::" + suffix))

def number(value):
    return int(value["#bigint"])

if control == "consent":
    assert last_value("disclosed") is True
    assert last_value("validDisclosure") is False
else:
    state = last_value("s")
    if control == "scope":
        assert number(state["visible"]) != 0
        assert state["visibleScope"] != state["expected"]
    elif control == "cursor":
        assert number(state["cursor"]) < number(state["highCursor"])
        assert number(state["visible"]) == 1 and state["deleted"] is True
    elif control == "work":
        assert state["phase"] == "stopped" and number(state["work"]) != 0
    else:
        raise AssertionError(control)
print(f"Verified {control} counterexample: {len(states) - 1} transitions")
PY
  printf 'negative-%s\t%s\tEXPECTED_VIOLATION\n' "$spatial_control" \
    "$((SECONDS - spatial_control_started))" >> "$spatial_artifacts/timing.tsv"
done

printf 'total\t%s\tPASS\n' "$((SECONDS - spatial_started))" >> "$spatial_artifacts/timing.tsv"
printf 'Dispatch spatial formal gate passed in %ss; artifacts: %s\n' \
  "$((SECONDS - spatial_started))" "$spatial_artifacts"
