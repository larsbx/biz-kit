#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Put the verified installation's bin first on PATH before calling this script.
# Do not restore compiled project proofs: rebuild the inspected source head.
lean --version
lake --version
lake clean
lake build

# Replay the complete imported environment in the Lean kernel, including the
# separate bundle and lease modules. This is not a different kernel implementation.
lake env leanchecker --fresh --verbose BizKitEventProofs
lake env leanchecker --fresh --verbose BizKitOutcomeAdmission
lake env leanchecker --fresh --verbose BizKitInventory

audit_sha=46024e005996495c65ef609368e11ab39c4222e3
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/bizkit-axiom-audit.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
git clone --quiet --depth 1 --branch v0.1.2 \
  https://github.com/leanprover-community/axiom-audit.git "$scratch/audit"
test "$(git -C "$scratch/audit" rev-parse HEAD)" = "$audit_sha"
cp lean-toolchain "$scratch/audit/lean-toolchain"
(cd "$scratch/audit" && lake build)

# The audit selects declarations by defining MODULE, not their namespace.
# Auditing only BizKitEventProofs would omit BizKitBundles and BizKitLeases.
for root in BizKitLeases BizKitBundles BizKitDispatch BizKitEventProofs BizKitOutcomeAdmission BizKitInventory; do
  lake env "$scratch/audit/.lake/build/bin/axiom-audit" \
    --root "$root" --allow propext,Classical.choice,Quot.sound
done
