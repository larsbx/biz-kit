#!/usr/bin/env bash
# Failure injection for biz-kit-cd, on adder-ws, against a throwaway checkout,
# fake toolchain, fake CI gate and a test unit on ports 18401/18400. Never
# touches ~/biz-kit, biz-kit-stack.service or the live state.
#
#   run.sh [path to biz-kit-cd]     default: the copy beside this directory
#
# Prints every scenario's checks with observed and expected values; exits 0
# only if all pass.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CD="${1:-$here/../bin/biz-kit-cd}"
W="$(mktemp -d)"
cleanup() {
  systemctl --user stop biz-kit-cd-test-stack.service 2>/dev/null
  systemctl --user reset-failed biz-kit-cd-test-stack.service 2>/dev/null
  rm -f "$HOME/.config/systemd/user/biz-kit-cd-test-stack.service"
  systemctl --user daemon-reload
  rm -rf "$W"
}
trap cleanup EXIT
"$here/setup.sh" "$W"
sleep 1
pass=0
fail=0

cd_run() {
  env PATH="$W/bin:$PATH" XDG_STATE_HOME="$W/state" BIZKIT_REPO="$W/repo" \
    BIZKIT_STACK_UNIT=biz-kit-cd-test-stack.service BIZKIT_HEALTH_PORTS="18401 18400" \
    BIZKIT_CD_GATE="$W/gate" "$CD" >>"$W/log/cd" 2>&1
}
# push <message> <path=content | -path> ...
push() {
  local msg="$1"
  shift
  cd "$W/seed"
  for spec in "$@"; do
    case "$spec" in
      -*) git rm -q "${spec#-}" ;;
      *) mkdir -p "$(dirname "${spec%%=*}")"; echo "${spec#*=}" >"${spec%%=*}"; git add "${spec%%=*}" ;;
    esac
  done
  git commit -qm "$msg" && git push -q origin main
  git rev-parse --short HEAD
}
short() { cut -c1-7 "$1" 2>/dev/null || echo none; }
head_of() { git -C "$W/repo" rev-parse --short HEAD; }
started() { systemctl --user show biz-kit-cd-test-stack.service -p ActiveEnterTimestampMonotonic --value; }
http() { curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18401/; }
notes() { grep -c "$1" "$W/log/notify" 2>/dev/null || echo 0; }
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); echo "  ok   $1 ($2)"
  else
    fail=$((fail + 1)); echo "  FAIL $1: got '$2', want '$3'"
  fi
}

echo "baseline"
cd_run; check "first run exits" "$?" 0
v1=$(head_of); check "checkpoint" "$(short "$W/state/biz-kit-cd/deployed")" "$v1"

echo "S1 CI pending: nothing moves"
v2=$(push v2 apps/app.txt=v2 desktop/ui.txt=v2)
echo 75 >"$W/gate-result"; cd_run; check "exit" "$?" 0
check "checkout" "$(head_of)" "$v1"
check "checkpoint" "$(short "$W/state/biz-kit-cd/deployed")" "$v1"

echo "S2 CI failed: refused, notified once across wake-ups"
echo 1 >"$W/gate-result"; cd_run; check "exit" "$?" 0; cd_run
check "notifications for two wake-ups" "$(notes "its CI failed")" 1
check "checkout" "$(head_of)" "$v1"

echo "S3 CI green, backend and desktop changed"
echo 0 >"$W/gate-result"; before=$(started); cd_run; check "exit" "$?" 0
check "checkout" "$(head_of)" "$v2"
check "checkpoint" "$(short "$W/state/biz-kit-cd/deployed")" "$v2"
check "compiled" "$(cat "$W/repo/_build/dev/compiled")" "$v2"
check "desktop built" "$(cat "$W/repo/desktop/src-tauri/target/release/biz-kit")" "$v2"
check "artifacts retained" "$(short "$W/state/biz-kit-cd/good/commit")" "$v2"
check "stack restarted" "$([ "$(started)" != "$before" ] && echo yes)" yes

echo "S4 compile failure: rolled back, running stack untouched"
v3=$(push v3 apps/app.txt=v3 BREAK_COMPILE=1)
before=$(started); cd_run; check "exit" "$?" 1
check "checkout" "$(head_of)" "$v2"
check "deps restored (deps.get had run for v3)" "$(cat "$W/repo/deps/fetched")" "$v2"
check "checkpoint" "$(short "$W/state/biz-kit-cd/deployed")" "$v2"
check "failed commit recorded" "$(short "$W/state/biz-kit-cd/failed")" "$v3"
check "stack not restarted" "$(started)" "$before"
check "stack serving" "$(http)" 404

echo "S5 a failed commit is not retried"
cd_run; check "exit" "$?" 0
check "checkout" "$(head_of)" "$v2"

echo "S6 stack unhealthy after restart: rolled back and old stack restarted"
push v4 -BREAK_COMPILE apps/app.txt=v4 STACK_BROKEN=1 >/dev/null
cd_run; check "exit" "$?" 1
check "checkout" "$(head_of)" "$v2"
check "build restored" "$(cat "$W/repo/_build/dev/compiled")" "$v2"
check "stack serving at last good" "$(http)" 404
check "notified" "$(notes "stack not healthy after restart")" 1

echo "S7 desktop build failure: last good binary restored"
push v5 -STACK_BROKEN desktop/ui.txt=v5 BREAK_DESKTOP=1 >/dev/null
cd_run; check "exit" "$?" 1
check "checkout" "$(head_of)" "$v2"
check "desktop binary" "$(cat "$W/repo/desktop/src-tauri/target/release/biz-kit")" "$v2"

echo "S8 docs-only commit: deployed without a restart"
v6a=$(push v6a -BREAK_DESKTOP)
cd_run; check "catch-up exit" "$?" 0
check "caught up" "$(head_of)" "$v6a"
v6=$(push v6 docs/readme.md=v6)
before=$(started); cd_run; check "exit" "$?" 0
check "checkout" "$(head_of)" "$v6"
check "stack not restarted" "$(started)" "$before"

echo "S9 refused checkout states leave everything in place"
v7=$(push v7 apps/app.txt=v7)
echo local >>"$W/repo/apps/app.txt"; cd_run; check "tracked edit: exit" "$?" 1
check "tracked edit: kept" "$(tail -1 "$W/repo/apps/app.txt")" local
git -C "$W/repo" checkout -q apps/app.txt
touch "$W/repo/untracked"; cd_run; check "untracked file: exit" "$?" 1
check "untracked file: kept" "$([ -e "$W/repo/untracked" ] && echo yes)" yes
rm "$W/repo/untracked"
git -C "$W/repo" checkout -q -b other; cd_run; check "off main: exit" "$?" 1
git -C "$W/repo" checkout -q --detach; cd_run; check "detached: exit" "$?" 1
check "detached: notified" "$(notes "detached HEAD")" 1
git -C "$W/repo" checkout -q main; git -C "$W/repo" branch -q -D other
git -C "$W/repo" commit -q --allow-empty -m local-only; cd_run; check "local commit ahead: exit" "$?" 1
check "local commit kept" "$(git -C "$W/repo" log -1 --format=%s)" local-only
check "nothing deployed" "$(short "$W/state/biz-kit-cd/deployed")" "$v6"
v7b=$(push v7b apps/other.txt=1); cd_run; check "diverged: exit" "$?" 1
check "diverged: local commit kept" "$(git -C "$W/repo" log -1 --format=%s)" local-only
git -C "$W/repo" reset -q --hard "$v6"
check "all refusals notified" "$(notes "skipped:\|stopped:")" 6

echo "S10 rollback that cannot recover: exit 2, loud"
touch "$W/STACK_DOWN"
cd_run; check "exit" "$?" 2
check "notified" "$(notes "ROLLBACK FAILED")" 1
rm -f "$W/STACK_DOWN" "$W/state/biz-kit-cd/failed"

echo "S11 lock: a second run waits for the first"
flock "$W/state/biz-kit-cd/lock" sleep 3 &
sleep 0.3; t0=$(date +%s); cd_run; t1=$(date +%s)
check "waited for the lock" "$([ $((t1 - t0)) -ge 2 ] && echo yes)" yes
check "then deployed" "$(head_of)" "$v7b"

echo "S12 unhandled error after the fast-forward: the exit trap rolls back"
push v8 apps/app.txt=v8 >/dev/null
touch "$W/FAIL_RETAIN"; cd_run; check "exit" "$?" 1
rm -f "$W/FAIL_RETAIN"
check "checkout" "$(head_of)" "$v7b"
check "checkpoint" "$(short "$W/state/biz-kit-cd/deployed")" "$v7b"
check "notified" "$(notes "unexpected error")" 1
check "stack serving at last good" "$(http)" 404

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
