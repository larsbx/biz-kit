#!/usr/bin/env bash
# Moves the vendored Datastar bundle (Section 26.1) to an upstream release:
# the hashed file and its unhashed copy replaced, VENDOR.md's row rewritten.
# A release-triggered dependency-review change, not a build-time fetch.
#
#   scripts/vendor-datastar.sh DIR        # to upstream's latest release
#   scripts/vendor-datastar.sh DIR TAG    # to TAG
#
# Prints the tag it moved to; prints nothing when DIR already has it.
# GH_TOKEN, when set, authenticates the release lookup.

set -euo pipefail
cd "$(dirname "$0")/.."

dir=$1
upstream=starfederation/datastar
tag=${2:-$(curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
  "https://api.github.com/repos/$upstream/releases/latest" | jq -r .tag_name)}

# | `datastar-<version>.<hash12>.js` | <upstream> | <version> | `<sha256>` |
row=$(grep '^| `datastar-' "$dir/VENDOR.md")
old_file=$(cut -d'`' -f2 <<<"$row")
old_version=$(awk -F'|' '{gsub(/ /, "", $4); print $4}' <<<"$row")
old_sha=$(cut -d'`' -f4 <<<"$row")
[ "$tag" = "$old_version" ] && exit 0

bundle=$(mktemp)
trap 'rm -f "$bundle"' EXIT
curl -fsSL "https://raw.githubusercontent.com/$upstream/$tag/bundles/datastar.js" -o "$bundle"
sha=$(sha256sum "$bundle" | cut -d' ' -f1)
new_file="datastar-$tag.${sha:0:12}.js"

rm "$dir/$old_file"
cp "$bundle" "$dir/$new_file"
cp "$bundle" "$dir/datastar.js"
sed -i "s|$old_file|$new_file|g; s/| $old_version |/| $tag |/; s/$old_sha/$sha/" "$dir/VENDOR.md"
echo "$tag"
