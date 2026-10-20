#!/usr/bin/env bash
# The ledger's own specs (the change feed), checked as the task core checks
# its specs (apps/task_core/spec/check.sh). Arguments name specs here.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SPECS_DIR=$here exec "$here/../../task_core/spec/check.sh" "$@"
