#!/usr/bin/env bash
# Install the Rust evaluator that the installed Quint CLI expects, where it
# looks for it ($QUINT_HOME or ~/.quint, rust-evaluator-<version>/).
#
# Left to itself, Quint lists releases through api.github.com without a token.
# Shared CI runners exhaust that anonymous rate limit, and the run fails before
# any model is checked. The release asset's direct download URL is not
# API-rate-limited, so fetch it from there once, before Quint runs.
#
# Usage: scripts/quint-evaluator.sh [path to the quint executable]
set -euo pipefail

bin=$(readlink -f "${1:-$(command -v quint)}")
manager="$(dirname "$bin")/rust/binaryManager.js"
version=$(sed -n "s/^exports\.QUINT_EVALUATOR_VERSION = '\(v[0-9.]*\)';$/\1/p" "$manager")
[ -n "$version" ] || { echo "no evaluator version in $manager" >&2; exit 1; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) target=x86_64-unknown-linux-gnu ;;
  Linux-aarch64) target=aarch64-unknown-linux-gnu ;;
  Darwin-arm64) target=aarch64-apple-darwin ;;
  Darwin-x86_64) target=x86_64-apple-darwin ;;
  *) echo "unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

dest="${QUINT_HOME:-$HOME/.quint}/rust-evaluator-$version"
[ -x "$dest/quint_evaluator" ] && exit 0
mkdir -p "$dest"
curl -fsSL --retry 3 \
  "https://github.com/informalsystems/quint/releases/download/evaluator/$version/quint_evaluator-$target.tar.gz" |
  tar -xz -C "$dest" quint_evaluator
echo "Quint evaluator $version installed at $dest"
