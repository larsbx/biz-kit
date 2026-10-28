#!/usr/bin/env bash
set -euo pipefail

# The digest is the official GitHub release asset digest, independently
# downloaded and checked when this pin was introduced. Never execute a
# restored cache entry until its bytes match this committed digest.
version=4.35.0
digest=7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d
package_dir=$(cd "$(dirname "$0")" && pwd)
if [[ $(cat "$package_dir/lean-toolchain") != "leanprover/lean4:v$version" ]]; then
  echo "ERROR: update the reviewed archive pin when changing lean-toolchain" >&2
  exit 1
fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 || $# != 1 ]]; then
  echo "Usage: bash install-toolchain.sh NEW_INSTALL_DIRECTORY (Linux x86_64)" >&2
  exit 1
fi
destination=$1
if [[ -e "$destination" ]]; then
  echo "ERROR: installation destination must not exist: $destination" >&2
  exit 1
fi
cache_dir=${BIZKIT_LEAN_ARCHIVE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bizkit-lean}
mkdir -p "$cache_dir" "$(dirname "$destination")"
archive="$cache_dir/lean-$version-linux.tar.zst"
scratch=$(mktemp -d "$(dirname "$destination")/.lean-install.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
verify() { printf '%s  %s\n' "$digest" "$1" | sha256sum --check --status; }
if [[ ! -f "$archive" ]]; then
  # Direct release asset avoids the previously failing releases.lean-lang.org
  # redirect. TLS verification stays enabled; retries never bypass integrity.
  curl --fail --location --show-error --silent --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 2 \
    "https://github.com/leanprover/lean4/releases/download/v$version/lean-$version-linux.tar.zst" \
    --output "$scratch/archive.tar.zst"
  if ! verify "$scratch/archive.tar.zst"; then
    echo "ERROR: downloaded Lean archive failed SHA-256 verification" >&2
    exit 1
  fi
  mv "$scratch/archive.tar.zst" "$archive"
fi
if ! verify "$archive"; then
  echo "ERROR: cached Lean archive failed SHA-256 verification: $archive" >&2
  exit 1
fi
echo "Verified Lean $version archive SHA-256: $digest"
mkdir "$scratch/toolchain"
tar --zstd --no-same-owner -xf "$archive" --strip-components=1 -C "$scratch/toolchain"
mv "$scratch/toolchain" "$destination"
echo "Installed verified toolchain at $destination"
