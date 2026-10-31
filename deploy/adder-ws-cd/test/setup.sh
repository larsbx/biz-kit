#!/usr/bin/env bash
# Builds the fixture for run.sh in work directory $1: a bare origin, a seed
# clone to push from, the checkout under test, a fake toolchain and gate, and
# a static test unit standing in for biz-kit-stack.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
W="$1"
mkdir -p "$W/bin" "$W/state" "$W/log"

git init -q --bare -b main "$W/origin.git"
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
cd "$W/seed"
git config user.email test@example.invalid
git config user.name test
mkdir -p apps desktop docs
echo v1 >apps/app.txt
echo v1 >desktop/ui.txt
printf '_build/\ndeps/\ndesktop/src-tauri/target/\n' >.gitignore
git add -A && git commit -qm v1 && git push -q origin main
git clone -q "$W/origin.git" "$W/repo"
git -C "$W/repo" config user.email test@example.invalid
git -C "$W/repo" config user.name test

# mix: deps.get records the commit in deps/, compile in _build/dev, unless the
# commit asks to break.
printf '%s\n' '#!/bin/sh' 'head=$(git rev-parse --short HEAD)' 'case "$1" in' \
  '  deps.get) mkdir -p deps && echo "$head" >deps/fetched ;;' \
  '  compile) [ -e BREAK_COMPILE ] && exit 1; mkdir -p _build/dev && echo "$head" >_build/dev/compiled ;;' \
  'esac' >"$W/bin/mix"
# npx (from desktop/): writes the binary unless the commit asks to break.
printf '%s\n' '#!/bin/sh' '[ -e ../BREAK_DESKTOP ] && exit 1' \
  'mkdir -p src-tauri/target/release && git rev-parse --short HEAD >src-tauri/target/release/biz-kit' >"$W/bin/npx"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/npm"
# notify-send -a biz-kit-cd "biz-kit deploy" <message>
printf '#!/bin/sh\necho "$4" >>"%s/log/notify"\n' "$W" >"$W/bin/notify-send"
# rsync: fails copying into a new artifact set when FAIL_RETAIN exists, to
# inject an error that no step handles.
printf '#!/bin/sh\ncase "$*" in *good.new*) [ -e "%s/FAIL_RETAIN" ] && exit 1 ;; esac\nexec /usr/bin/rsync "$@"\n' "$W" >"$W/bin/rsync"
printf '#!/bin/sh\nexit "$(cat "%s/gate-result")"\n' "$W" >"$W/gate"
chmod +x "$W/bin/"* "$W/gate"
echo 0 >"$W/gate-result"

# Static (no [Install]): is-enabled succeeds, and it never starts at boot.
printf '%s\n' '[Unit]' 'Description=biz-kit-cd failure-injection stand-in stack' '' '[Service]' \
  "ExecStart=/usr/bin/python3 -I $here/fake-stack.py $W/repo $W/STACK_DOWN" \
  >"$HOME/.config/systemd/user/biz-kit-cd-test-stack.service"
systemctl --user daemon-reload
systemctl --user restart biz-kit-cd-test-stack.service
