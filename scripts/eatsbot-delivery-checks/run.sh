#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat <<'HELP'
Usage: run.sh REPOSITORY {baseline|launch|quint} [COMMIT]
Default commit: 3278f2d1ba3e22986927eb2ee50170c7b148ef62
BEAM_IMAGE: required for baseline and launch, an Elixir 1.19.0 / OTP 27.3.4 Docker image.
POSTGRES_IMAGE: defaults to postgres:16.
HELP
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ $# -lt 2 || $# -gt 3 ]]; then usage >&2; exit 2; fi
repo=$1
mode=$2
ref=${3:-3278f2d1ba3e22986927eb2ee50170c7b148ef62}
case "$mode" in baseline|launch|quint) ;; *) usage >&2; exit 2 ;; esac
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
sha=$(git -C "$repo" rev-parse --verify --end-of-options "$ref^{commit}")
scratch=$(mktemp -d)
network=''
postgres=''
cleanup() {
  if [[ -n $postgres ]]; then docker rm -f -v "$postgres" >/dev/null || true; fi
  if [[ -n $network ]]; then docker network rm "$network" >/dev/null || true; fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git -C "$repo" archive "$sha" | tar -xf - -C "$scratch"
printf 'revision=%s mode=%s\n' "$sha" "$mode"

if [[ $mode == quint ]]; then
  (cd "$scratch" && bash formal/check_coverage.sh)
  exit
fi

: "${BEAM_IMAGE:?Set BEAM_IMAGE to an Elixir 1.19.0 / OTP 27.3.4 Docker image}"
docker info >/dev/null
network=$(docker network create "eatsbot-acceptance-${scratch##*.}")
postgres=$(docker run -d --network "$network" --network-alias test-postgres \
  -e POSTGRES_PASSWORD=eatsbot-fixture "${POSTGRES_IMAGE:-postgres:16}")
ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  if docker exec "$postgres" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ $ready != true ]]; then docker logs "$postgres" >&2; exit 1; fi

if [[ $mode == launch ]]; then
  cp "$here/launch_blockers_test.exs" "$scratch/apps/restaurant_host/test/delivery_launch_probe_test.exs"
fi

docker run --rm -i --network "$network" \
  --mount "type=bind,src=$scratch,dst=/snapshot,readonly" \
  -e EVENTSTORE_HOST=test-postgres -e EVENTSTORE_USERNAME=postgres \
  -e EVENTSTORE_PASSWORD=eatsbot-fixture -e MIX_ENV=test \
  "$BEAM_IMAGE" bash -s -- "$mode" <<'CONTAINER'
set -euo pipefail
elixir -e 'unless System.version() == "1.19.0", do: System.halt(1)'
otp_release=$(erl -noshell -eval 'io:format("~s", [filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])]), halt().')
[[ $(cat "$otp_release") == 27.3.4 ]]
mkdir -p /work/biz-kit
cp -a /snapshot/. /work/biz-kit/
cd /work/biz-kit
mix local.hex --force
mix local.rebar --force
mix deps.get --check-locked
if [[ $1 == baseline ]]; then
  (cd apps/order_core && mix test --no-start --seed 0)
  (cd apps/restaurant_core && mix test --no-start --seed 0)
  (cd apps/fulfillment_core && mix test --no-start --seed 0)
  (
    cd apps/coop_substrate
    mix test test/restaurant_admission_test.exs test/restaurant_delivery_test.exs \
      test/log_test.exs test/governance_authorization_test.exs --warnings-as-errors --seed 0
  )
  (cd apps/restaurant_host && mix test --no-start --warnings-as-errors --seed 0)
else
  (cd apps/coop_substrate && mix event_store.create --quiet && mix event_store.init --quiet)
  probe_output=$(mktemp)
  status=0
  (cd apps/restaurant_host &&
    mix test --no-start --warnings-as-errors --seed 0 test/delivery_launch_probe_test.exs) \
    | tee "$probe_output" || status=$?
  if grep -Fq 'DELIVERY_BLOCKER delayed_pickup_observation_unrepresented' "$probe_output"; then
    printf '%s\n' 'Launch blocked: V1 refuses pickup after withdrawal and has no distinct observation event.' >&2
    exit 1
  fi
  exit "$status"
fi
CONTAINER
