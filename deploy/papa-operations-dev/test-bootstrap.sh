#!/usr/bin/env bash
set -euo pipefail

src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export HOME=$tmp/home
export TEST_LOG=$tmp/calls
export PATH=$tmp/bin:$PATH
base=$HOME/ops/bizops-dev
stage=$tmp/upload
mkdir -p "$stage" "$tmp/bin" "$tmp/release/bin" "$HOME/data/pglocal19/bin"

cp "$src/install-bizops-dev.sh" "$stage/"
cat > "$HOME/data/pglocal19/bin/psql" <<'STUB'
#!/usr/bin/env bash
[[ $# == 13 && "${*:1:11}" == '-h /tmp -p 5432 -U postgres -v ON_ERROR_STOP=1 -At -d postgres' && "${12}" == -c ]] || exit 90
sql=${!#}
case $sql in
  "select 1 from pg_roles where rolname='bizops_dev'")
    if grep -qx 'create role' "$TEST_LOG"; then printf '1\n'; fi ;;
  "select 1 from pg_database where datname='bizops_dev_eventstore'" | \
  "select 1 from pg_database where datname='bizops_dev_task_host'" | \
  "select 1 from pg_database where datname='bizops_dev_spruce_goose'")
    db=${sql#*\'}
    db=${db%\'}
    if grep -qx "create database $db owner bizops_dev" "$TEST_LOG"; then printf '1\n'; fi ;;
  "create role bizops_dev login password "*) echo 'create role' >> "$TEST_LOG" ;;
  "alter role bizops_dev login password "*) echo 'alter role' >> "$TEST_LOG" ;;
  'create database bizops_dev_eventstore owner bizops_dev' | \
  'create database bizops_dev_task_host owner bizops_dev' | \
  'create database bizops_dev_spruce_goose owner bizops_dev')
    echo "$sql" >> "$TEST_LOG" ;;
  *) exit 90 ;;
esac
STUB
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  '--user daemon-reload' | '--user enable bizops-dev.service' | \
  '--user restart bizops-dev.service' | '--user --no-pager status bizops-dev.service')
    printf '%s\n' "$*" >> "$TEST_LOG" ;;
  *) exit 91 ;;
esac
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
[[ ${!#} == http://127.0.0.1:4001/operations ]] || exit 92
printf 'loopback readiness\n' >> "$TEST_LOG"
STUB
cat > "$tmp/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
base=$HOME/ops/bizops-dev
[[ $# == 13 && "$1 $2 $3 $4" == '--user --wait --pipe --quiet' ]]
[[ "$5" == -p && "$6" == "EnvironmentFile=$base/env" ]]
[[ "$7" == -p && "$8" == "WorkingDirectory=$base/state" ]]
[[ "$9" == --setenv=CODE=* && "${10}" == --setenv=APPROVE=* ]]
[[ "${11}" == "$base/release/bin/orchestration" && "${12}" == eval ]]
export CODE=${9#--setenv=CODE=} APPROVE=${10#--setenv=APPROVE=}
exec "${@:11}"
STUB
cat > "$tmp/release/bin/orchestration" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == eval && "$2" == *'http://127.0.0.1:4001'* ]]
printf 'fetch %s\n' "$CODE" >> "$TEST_LOG"
case "$CODE" in
  ZZZZ-ZZZZ-ZZZZ) echo 'fixture: unknown code' >&2; exit 1 ;;
  ABCD-EFGH-JKLM) printf '%s\n' "$APPROVE" >> "$TEST_LOG" ;;
  *) exit 93 ;;
esac
STUB
chmod +x "$HOME/data/pglocal19/bin/psql" "$tmp/bin/"* "$tmp/release/bin/orchestration"
tar -czf "$tmp/release.tgz" -C "$tmp/release" .

run_install() {
  bash "$stage/install-bizops-dev.sh" "$tmp/release.tgz"
}

if run_install >"$tmp/install.log" 2>&1; then
  echo 'Installer accepted a missing helper' >&2
  exit 1
fi
grep -F 'Missing or unreadable approval helper' "$tmp/install.log"
[[ ! -e "$base" && ! -e "$TEST_LOG" ]]

cp "$src/approve.sh" "$stage/"
chmod 0644 "$stage/approve.sh"
: > "$TEST_LOG"
run_install
cmp "$stage/approve.sh" "$base/approve.sh"
[[ $(stat -c %a "$base/approve.sh") == 700 ]]
grep -Fx 'EVENTSTORE_DATABASE=bizops_dev_eventstore' "$base/env"
grep -E '^TASK_HOST_DATABASE_URL=.*/bizops_dev_task_host$' "$base/env" >/dev/null
grep -E '^SPRUCE_GOOSE_DATABASE_URL=.*/bizops_dev_spruce_goose$' "$base/env" >/dev/null
for file in env db.password operations.json; do
  cp "$base/$file" "$tmp/$file"
done
touch "$base/keys/synthetic" "$base/state/synthetic"
rm "$base/approve.sh"
run_install
cmp "$stage/approve.sh" "$base/approve.sh"
[[ $(stat -c %a "$base/approve.sh") == 700 ]]
[[ -x "$base/release.old/bin/orchestration" ]]
[[ -f "$base/keys/synthetic" && -f "$base/state/synthetic" ]]
for file in env db.password operations.json; do
  cmp "$tmp/$file" "$base/$file"
done
[[ $(grep -c '^--user restart bizops-dev.service$' "$TEST_LOG") == 2 ]]
[[ $(grep -c '^loopback readiness$' "$TEST_LOG") == 4 ]]
[[ $(grep -c '^create role$' "$TEST_LOG") == 1 ]]
[[ $(grep -c '^alter role$' "$TEST_LOG") == 1 ]]
for db in eventstore task_host spruce_goose; do
  [[ $(grep -c "^create database bizops_dev_$db owner bizops_dev$" "$TEST_LOG") == 1 ]]
done

: > "$TEST_LOG"
if "$base/approve.sh" ABCD-EFGH-JKLM --typo; then
  echo 'Approval helper accepted an unknown option' >&2
  exit 1
fi
[[ ! -s "$TEST_LOG" ]]
if "$base/approve.sh" ZZZZ-ZZZZ-ZZZZ --yes; then
  echo 'Approval helper returned success for the unknown-code fixture' >&2
  exit 1
fi
"$base/approve.sh" ABCD-EFGH-JKLM
"$base/approve.sh" ABCD-EFGH-JKLM --yes
diff -u - "$TEST_LOG" <<'EXPECTED'
fetch ZZZZ-ZZZZ-ZZZZ
fetch ABCD-EFGH-JKLM
no
fetch ABCD-EFGH-JKLM
yes
EXPECTED
echo 'Bootstrap shell checks passed'
