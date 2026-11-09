#!/usr/bin/env bash
# Independent finite model acceptance. A missing tool, parser error, timeout,
# lost mutation witness, or changed source is a failure, never a passing probe.
set -euo pipefail
model_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$model_dir/../.." && pwd)
quint_cli=${QUINT_BIN:-quint}
evidence_dir=${COMMERCIAL_QUINT_EVIDENCE_DIR:-$(mktemp -d "${RUNNER_TEMP:-/tmp}/commercial-admission-quint.XXXXXX")}
mkdir -p "$evidence_dir"
evidence_dir=$(cd "$evidence_dir" && pwd)
# Use an immutable input copy so a later working-tree edit cannot change a run.
cp "$model_dir/commercial_admission.qnt" "$evidence_dir/commercial_admission.qnt"
cp "$model_dir/check_commercial_admission.sh" "$evidence_dir/check_commercial_admission.sh"
sha256sum "$model_dir/commercial_admission.qnt" "$model_dir/check_commercial_admission.sh" > "$evidence_dir/source-sha256.txt"
git -C "$repo_dir" rev-parse HEAD > "$evidence_dir/git-head.txt"
git -C "$repo_dir" status --porcelain -- formal/quint/commercial_admission.qnt formal/quint/check_commercial_admission.sh > "$evidence_dir/source-status.txt"
"$quint_cli" --version > "$evidence_dir/quint-version.txt"
test "$(tr -d '\r\n' < "$evidence_dir/quint-version.txt")" = "0.33.1"
# Apalache 0.62.4 is compiled for Java 21 (class-file version 65). Refuse
# the hosted image's default Java 17 before starting any acceptance stage.
if ! java -version > "$evidence_dir/java-version.txt" 2>&1 ||
    ! grep -Fq 'Temurin-21.0.13+9' "$evidence_dir/java-version.txt"; then
  cat "$evidence_dir/java-version.txt" >&2
  echo "FAIL: pinned Apalache requires Temurin Java 21.0.13+9" >&2
  exit 1
fi
cd "$evidence_dir"
spec="$evidence_dir/commercial_admission.qnt"

required() {
  local label=$1
  shift
  if "$@" > "$label.log" 2>&1; then
    echo "PASS: $label"
  else
    tail -60 "$label.log" >&2
    echo "FAIL: $label (see $evidence_dir/$label.log)" >&2
    exit 1
  fi
}
required typecheck "$quint_cli" typecheck "$spec"
required scenarios "$quint_cli" test "$spec" --main=commercial_admission \
  --backend=typescript --max-samples=1 --seed=1 --verbosity=2
grep -Eq '25 passing' scenarios.log
required simulation "$quint_cli" run "$spec" --main=commercial_admission \
  --backend=typescript --invariant=safety --max-samples=1000 --max-steps=25 \
  --seed=1 --verbosity=1
grep -q '\[ok\] No violation found' simulation.log

# BOUNDED symbolic verification, not exhaustive exploration or liveness:
# nine transitions, at most five steps from the legacy state. The complete
# deterministic scenarios above include longer traces, and the simulation
# exercises all source mutation/authority actions rather than this slice alone.
required bounded timeout 600s "$quint_cli" verify "$spec" --main=commercial_admission \
  --step=boundedStep --invariant=safety --max-steps=5 --apalache-version=0.62.4 \
  --server-endpoint="${COMMERCIAL_APALACHE_ENDPOINT:-localhost:8857}" --verbosity=2
# Quint/translator failures have sometimes exited zero: require real success.
grep -q '\[ok\] No violation found' bounded.log
grep -q 'The outcome is: NoError' bounded.log

for mutant in profile activation profileBinding identity origin revision latest version authority member reservation intent event cas callerProfile recovery atomic discharge; do
  code=0
  init=preparedInit
  if [ "$mutant" = profile ] || [ "$mutant" = activation ]; then init=unprotectedPreparedInit; fi
  "$quint_cli" run "$spec" --main=commercial_admission --backend=typescript \
    --init="$init" --step="${mutant}Mutant" --invariant=safety \
    --max-samples=300 --max-steps=6 --seed=1 --verbosity=2 \
    --out-itf="${mutant}-counterexample.itf.json" > "${mutant}-counterexample.log" 2>&1 || code=$?
  if [ "$code" -ne 1 ] || ! grep -q '\[violation\]' "${mutant}-counterexample.log" \
      || [ ! -s "${mutant}-counterexample.itf.json" ]; then
    tail -60 "${mutant}-counterexample.log" >&2
    echo "FAIL: $mutant lacks the required invariant counterexample (exit $code)" >&2
    exit 1
  fi
  echo "PASS: $mutant counterexample"
done
# Refuse an execution whose inspected inputs changed during acceptance.
sha256sum --check "$evidence_dir/source-sha256.txt" > "$evidence_dir/source-unchanged.log"
printf '%s\n' 'COMMERCIAL_ADMISSION_QUINT_PASSED: 25 scenarios; 1000 sampled traces of 25 steps; 5-step bounded symbolic slice; 18 targeted counterexamples' | tee "$evidence_dir/result.txt"
printf 'Evidence: %s\n' "$evidence_dir"
