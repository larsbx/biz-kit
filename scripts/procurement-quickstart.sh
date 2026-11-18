#!/usr/bin/env bash
# Install/run the disposable evidence environment; never deploy or use a host DB.
set -euo pipefail
umask 077
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
usage() {
  cat <<'HELP'
Usage: bash scripts/procurement-quickstart.sh doctor|install|run|evidence DIRECTORY
  doctor    Check local Docker, Git, Python and clean committed source.
  install   Build the isolated toolchain image; no host toolchain installation.
  run       Build/reuse the image, replay formal models, run packaged acceptance.
  evidence  Check a run's container bundle against this checkout's exact HEAD.
Linux x86-64 and a LOCAL Docker engine are required. This is NOT deployment.
No host database, credentials, Docker socket, port or persistent volume is passed.
Evidence is kept in unique .artifacts/procurement-quickstart/ directories.
HELP
}
mode=${1:-help}
if [[ "$mode" == help || "$mode" == --help || "$mode" == -h ]]; then usage; exit 0; fi
case "$mode" in doctor|install|run|evidence) ;; *) usage >&2; exit 2;; esac
if [[ "$mode" == evidence ]]; then
  [[ $# == 2 ]] || { usage >&2; exit 2; }
  exec python3 "$root/tools/procurement-quickstart/evidence.py" "$2/container" \
    --revision "$(git -C "$root" rev-parse HEAD)"
fi
[[ $# == 1 ]] || { usage >&2; exit 2; }
for tool in git docker python3; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. See QUICKSTART_PROCUREMENT.md." >&2; exit 1; }
done
python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required"'
[[ "$(uname -s)" == Linux ]] || { echo 'Only Linux is supported by this runner.' >&2; exit 1; }
if [[ -n ${DOCKER_CONTEXT:-} ]]; then
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' "$DOCKER_CONTEXT")
elif [[ -n ${DOCKER_HOST:-} ]]; then
  endpoint=$DOCKER_HOST
else
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
fi
[[ "$endpoint" == unix://* ]] || { echo 'Refusing remote Docker: use a local Unix socket engine.' >&2; exit 1; }
[[ "$(docker info --format '{{.OSType}}')" == linux ]] || { echo 'Linux containers required.' >&2; exit 1; }
case "$(docker info --format '{{.Architecture}}')" in x86_64|amd64) ;; *) echo 'amd64 runner only; emulation is unverified.' >&2; exit 1;; esac
revision=$(git -C "$root" rev-parse HEAD)
# Ignore only generated evidence; edited or untracked application/tooling source is refused.
dirty=$(git -C "$root" status --porcelain --untracked-files=all -- . ':(exclude).artifacts/**')
[[ -z "$dirty" ]] || { echo 'Commit or stash source edits before collecting exact-revision evidence.' >&2; exit 1; }
[[ -f "$root/scripts/test-procurement-host.sh" ]] || { echo 'PR #334 host harness missing.' >&2; exit 1; }
echo "Preflight OK: $revision (local Linux/amd64 Docker; clean source)."
[[ "$mode" != doctor ]] || exit 0
# Work only with an exact, shallow Git snapshot. The user's .git config,
# credentials, ignored secrets and untracked files never enter the container.
parent="$root/.artifacts/procurement-quickstart"
mkdir -p "$parent"
run_dir=$(mktemp -d "$parent/$(date -u +%Y%m%dT%H%M%SZ)-${revision:0:12}-XXXXXX")
scratch=$(mktemp -d)
container_name="procurement-evidence-$(basename "$run_dir" | tr '[:upper:]' '[:lower:]')"
created=false
cleanup() {
  code=$?
  trap - EXIT INT TERM
  if [[ "$created" == true ]]; then
    if [[ ! -d "$run_dir/container" ]]; then
      docker stop --time 30 "$container_name" >/dev/null 2>&1 || true
      mkdir -p "$run_dir/container"
      docker cp "$container_name:/evidence/." "$run_dir/container/" >/dev/null 2>&1 || true
    fi
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  rm -rf "$scratch"
  echo "Evidence directory: $run_dir"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$revision" > "$run_dir/revision.txt"
git init -q "$scratch/source"
git -C "$scratch/source" -c protocol.file.allow=always fetch -q --depth=1 "$root" "$revision"
git -C "$scratch/source" checkout -q --detach FETCH_HEAD
# Committed source must be readable by the non-root container UID. The outer
# temporary directory stays private; no ignored local files are copied.
chmod -R a+rX "$scratch/source"
# Build context contains toolchain sources only, not the repository or secrets.
docker build --iidfile "$run_dir/image.id" \
  -f "$scratch/source/tools/procurement-quickstart/Dockerfile" \
  "$scratch/source/tools/procurement-quickstart" 2>&1 | tee "$run_dir/install.log"
image=$(cat "$run_dir/image.id")
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'No valid built image ID.' >&2; exit 1; }
docker image inspect --format '{{.Id}} {{json .RepoDigests}}' "$image" > "$run_dir/image.txt"
[[ "$mode" != install ]] || { echo "Installed evidence image $image; application not executed."; exit 0; }
# No published ports, privileged mode, host networking, socket mount or host env forwarding.
# Docker cp returns retained observations even when application compilation fails.
docker create --name "$container_name" --init --security-opt no-new-privileges \
  --cap-drop ALL --mount "type=bind,src=$scratch/source,dst=/source,readonly" \
  --env "SOURCE_REVISION=$revision" --env "QUICKSTART_IMAGE_ID=$image" "$image" > "$run_dir/container.id"
created=true
set +e
docker start --attach "$container_name" 2>&1 | tee "$run_dir/console.log"
transport_status=${PIPESTATUS[0]}
set -e
status=$(docker inspect --format '{{.State.ExitCode}}' "$container_name")
# Completion is mandatory: an attached-client failure cannot leave a running app.
running=$(docker inspect --format '{{.State.Running}}' "$container_name")
if [[ "$running" != false ]]; then
  docker stop --time 30 "$container_name" >/dev/null || true
  status=1
fi
mkdir "$run_dir/container"
docker cp "$container_name:/evidence/." "$run_dir/container/"
[[ "$status" == 0 && "$transport_status" == 0 ]] || {
  echo 'Execution failed; inspect console.log and container/result.json. No acceptance claimed.' >&2
  exit 1
}
python3 "$root/tools/procurement-quickstart/evidence.py" "$run_dir/container" --revision "$revision"
echo 'Scoped execution complete. No persistent UI, merge, or deployment was performed.'
