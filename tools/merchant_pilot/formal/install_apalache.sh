#!/usr/bin/env bash
set -euo pipefail
# Official v0.56.1 release asset digest, verified against the GitHub release metadata.
# Use tar without restoring archive ownership so root/container installs work too.
if [[ $# != 1 || -e $1 ]]; then
  echo 'Usage: bash install_apalache.sh NEW_QUINT_HOME' >&2
  exit 1
fi
pilot_destination=$1
mkdir -p "$(dirname "$pilot_destination")"
pilot_stage=$(mktemp -d "$(dirname "$pilot_destination")/.pilot-apalache.XXXXXX")
trap 'rm -rf "$pilot_stage"' EXIT
curl --fail --location --show-error --silent --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 2 \
  https://github.com/apalache-mc/apalache/releases/download/v0.56.1/apalache.tgz \
  --output "$pilot_stage/apalache.tgz"
printf '%s  %s\n' 91125e5a3646b9c9d3a7d921d3323f321fac5071909f72b3960c66ff2f998ee1 \
  "$pilot_stage/apalache.tgz" | sha256sum --check --status
mkdir -p "$pilot_stage/home/apalache-dist-0.56.1"
tar --no-same-owner -xzf "$pilot_stage/apalache.tgz" -C "$pilot_stage/home/apalache-dist-0.56.1"
test -x "$pilot_stage/home/apalache-dist-0.56.1/apalache/bin/apalache-mc"
mv "$pilot_stage/home" "$pilot_destination"
echo 'Installed digest-verified Apalache 0.56.1; set QUINT_HOME to this directory.'
