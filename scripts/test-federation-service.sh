#!/usr/bin/env bash
set -euo pipefail
# Stage only the two federation apps, sharing the existing dependency lock.
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/apps" "$stage/config"
cp -R "$root/apps/federation_core" "$root/apps/federation_service" "$stage/apps/"
printf 'defmodule FederationHarness.MixProject do\n use Mix.Project\n def project, do: [apps_path: "apps", deps: []]\nend\n' > "$stage/mix.exs"
printf 'import Config\n' > "$stage/config/config.exs"
cp "$root/mix.lock" "$stage/mix.lock"
cd "$stage"
mix deps.get --check-locked
# Audit the reachable federation graph; unused umbrella entries (e.g. JOSE)
# are inventoried separately by the full-lock audit job. Versions are unchanged.
mix deps.unlock --unused
mix hex.audit
MIX_ENV=test mix compile --warnings-as-errors
mix format --check-formatted 'apps/federation_service/mix.exs' 'apps/federation_service/lib/**/*.ex' 'apps/federation_service/test/**/*.exs'
mix test
