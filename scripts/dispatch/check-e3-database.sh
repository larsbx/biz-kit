#!/usr/bin/env bash
# Exercise the exact migration SQL only in newly created disposable databases.
# DATABASE_URL is intentionally ignored: it may name an existing app database.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sql_dir="$repo_root/apps/dispatch/priv/repo/e3"
command -v psql >/dev/null || { echo 'psql is required for E3 database acceptance' >&2; exit 1; }

export PGPASSWORD="${DISPATCH_E3_PGPASSWORD:-${PGPASSWORD:-postgres}}"
psql_cmd=(psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -P pager=off
  -h "${DISPATCH_E3_PGHOST:-127.0.0.1}"
  -p "${DISPATCH_E3_PGPORT:-5432}"
  -U "${DISPATCH_E3_PGUSER:-postgres}")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dispatch-e3-acceptance.XXXXXX")
db_prefix="dispatch_e3_acceptance_${BASHPID}_${RANDOM}"
db_counter=0
race_counter=0
created_dbs=()
background_pids=()

cleanup() {
  local result=$? db pid
  trap - EXIT
  for pid in "${background_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${background_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  for db in "${created_dbs[@]}"; do
    # Never interpolate an arbitrary existing database name into DROP DATABASE.
    if [[ "$db" =~ ^dispatch_e3_acceptance_[0-9]+_[0-9]+_[0-9]+$ ]]; then
      "${psql_cmd[@]}" -q -d postgres -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" >/dev/null ||
        echo "Cleanup failed for disposable database $db" >&2
    fi
  done
  rm -rf -- "$work_dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

query() { "${psql_cmd[@]}" -qAt -d "$current_db" -c "$1"; }
run_file() { "${psql_cmd[@]}" -q -d "$current_db" -f "$1"; }
new_fixture() {
  db_counter=$((db_counter + 1))
  current_db="${db_prefix}_${db_counter}"
  "${psql_cmd[@]}" -q -d postgres -c "CREATE DATABASE \"$current_db\"" >/dev/null
  created_dbs+=("$current_db")
  run_file "$sql_dir/fixture.sql"
}
legacy_insert() {
  local id=$1 participant=$2 mode=$3 status=$4
  query "INSERT INTO assignments
    (id, tenant_id, load_id, operator_participant_id, operator_exclusive, status, starts_at)
    SELECT e3_uuid($id), tenant_id,
      CASE WHEN tenant_id = e3_uuid(101) THEN e3_uuid(21) ELSE e3_uuid(22) END,
      id, $mode, '$status', '2026-11-06' FROM participants WHERE id = e3_uuid($participant)" >/dev/null
}
expect_preflight_failure() {
  local label=$1 expected=$2 before after
  before=$(query "SELECT md5(coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text, '[]')) FROM assignments a")
  if "${psql_cmd[@]}" -q -d "$current_db" --single-transaction -f "$sql_dir/up.sql" \
      >"$work_dir/preflight.log" 2>&1; then
    echo "FAIL: $label migration unexpectedly succeeded" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$work_dir/preflight.log"; then
    cat "$work_dir/preflight.log" >&2
    echo "FAIL: $label did not fail at its intended preflight" >&2
    exit 1
  fi
  after=$(query "SELECT md5(coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text, '[]')) FROM assignments a")
  [[ "$before" == "$after" ]] || { echo "FAIL: $label changed baseline rows" >&2; exit 1; }
  [[ $(query "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'assignments' AND column_name = 'operator_user_id'") == 0 ]] ||
    { echo "FAIL: $label did not roll back schema changes" >&2; exit 1; }
  echo "PASS: $label refuses migration atomically"
}

new_fixture
query "INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id, starts_at)
  VALUES (e3_uuid(100), e3_uuid(101), e3_uuid(21), e3_uuid(999), now())" >/dev/null
expect_preflight_failure 'missing participant identity' 'no tenant-matching participant User identity'

new_fixture
query "INSERT INTO assignments (id, tenant_id, load_id, operator_participant_id, starts_at)
  VALUES (e3_uuid(100), e3_uuid(102), e3_uuid(22), e3_uuid(11), now())" >/dev/null
expect_preflight_failure 'wrong-tenant participant identity' 'no tenant-matching participant User identity'

new_fixture
legacy_insert 100 11 true ACTIVE
legacy_insert 101 12 true ACTIVE
expect_preflight_failure 'cross-tenant exclusive/exclusive baseline' 'conflicting ACTIVE assignments'

new_fixture
legacy_insert 100 11 true ACTIVE
legacy_insert 101 12 false ACTIVE
expect_preflight_failure 'cross-tenant exclusive/concurrent baseline' 'conflicting ACTIVE assignments'

new_fixture
legacy_insert 100 11 false ACTIVE
expect_preflight_failure 'legacy active concurrent provenance' 'lack original trusted role provenance'

new_fixture
legacy_insert 100 11 true PLANNED
legacy_insert 101 12 false CANCELLED
"${psql_cmd[@]}" -q -d "$current_db" --single-transaction -f "$sql_dir/up.sql"
run_file "$sql_dir/test_helpers.sql"
run_file "$sql_dir/acceptance.sql"

wait_for() {
  local condition=$1 label=$2 attempt
  for ((attempt = 0; attempt < 150; attempt++)); do
    if [[ $(query "$condition") == t ]]; then return 0; fi
    sleep 0.1
  done
  echo "FAIL: timed out waiting for $label" >&2
  query "SELECT application_name, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE datname = current_database()" >&2 || true
  cat "$work_dir"/race-*.log >&2 || true
  exit 1
}

# The first session remains idle inside its transaction through a FIFO. The
# second must be observed waiting on a PostgreSQL lock before we release it.
# C/C is also tested while the first transaction stays open, proving coexistence
# does not accidentally serialize all work for a User.
race() {
  local label=$1 first_sql=$2 second_sql=$3 finish=$4 expected_state=$5 active_count=$6
  local first_pid second_pid writer_fd first_app second_app fifo log_first log_second
  race_counter=$((race_counter + 1))
  first_app="e3_first_${BASHPID}_${race_counter}"
  second_app="e3_second_${BASHPID}_${race_counter}"
  fifo="$work_dir/race-${race_counter}.fifo"
  log_first="$work_dir/race-${race_counter}-first.log"
  log_second="$work_dir/race-${race_counter}-second.log"
  mkfifo "$fifo"
  PGAPPNAME="$first_app" PGOPTIONS='-c statement_timeout=20000 -c lock_timeout=15000' \
    "${psql_cmd[@]}" -qAt -d "$current_db" <"$fifo" >"$log_first" 2>&1 &
  first_pid=$!
  background_pids+=("$first_pid")
  exec {writer_fd}>"$fifo"
  printf '%s\n' 'BEGIN ISOLATION LEVEL READ COMMITTED;' "$first_sql" "SELECT 'e3_writer_ready';" >&"$writer_fd"
  wait_for "SELECT EXISTS (SELECT 1 FROM pg_stat_activity
    WHERE datname = current_database() AND application_name = '$first_app'
      AND state = 'idle in transaction' AND query LIKE '%e3_writer_ready%')" "$label first write"

  PGAPPNAME="$second_app" PGOPTIONS='-c statement_timeout=20000 -c lock_timeout=15000' \
    "${psql_cmd[@]}" -qAt -d "$current_db" -c "BEGIN ISOLATION LEVEL READ COMMITTED; $second_sql COMMIT;" >"$log_second" 2>&1 &
  second_pid=$!
  background_pids+=("$second_pid")
  if [[ "$expected_state" == coexist ]]; then
    wait_for "SELECT EXISTS (SELECT 1 FROM assignments WHERE id = e3_uuid(401) AND status = 'ACTIVE')" "$label second commit while first stays open"
  else
    wait_for "SELECT EXISTS (SELECT 1 FROM pg_stat_activity
      WHERE datname = current_database() AND application_name = '$second_app'
        AND wait_event_type = 'Lock')" "$label database blocking"
  fi

  printf '%s;\n' "$finish" >&"$writer_fd"
  exec {writer_fd}>&-
  if ! wait "$first_pid"; then cat "$log_first" >&2; echo "FAIL: $label first transaction" >&2; exit 1; fi
  if [[ "$expected_state" == success || "$expected_state" == coexist ]]; then
    if ! wait "$second_pid"; then cat "$log_second" >&2; echo "FAIL: $label second transaction" >&2; exit 1; fi
  else
    if wait "$second_pid"; then echo "FAIL: $label conflicting second transaction committed" >&2; exit 1; fi
    if ! grep -Fq "$expected_state" "$log_second"; then
      cat "$log_second" >&2; echo "FAIL: $label wrong failure state" >&2; exit 1
    fi
  fi
  background_pids=()
  [[ $(query "SELECT count(*) FROM assignments WHERE status = 'ACTIVE'") == "$active_count" ]] ||
    { echo "FAIL: $label unexpected ACTIVE count" >&2; exit 1; }
  [[ $(query "SELECT NOT EXISTS (SELECT operator_user_id FROM assignments WHERE status = 'ACTIVE' GROUP BY operator_user_id HAVING count(*) > 1 AND bool_or(operator_exclusive))") == t ]] ||
    { echo "FAIL: $label left an incompatible committed pair" >&2; exit 1; }
  echo "PASS: $label"
}

while read -r first_mode second_mode rejection; do
  query 'TRUNCATE assignments' >/dev/null
  race "concurrent $first_mode/$second_mode commit" \
    "SELECT e3_insert(400, 11, $first_mode);" "SELECT e3_insert(401, 12, $second_mode);" \
    COMMIT "$rejection" 1
  query 'TRUNCATE assignments' >/dev/null
  race "concurrent $first_mode/$second_mode rollback" \
    "SELECT e3_insert(400, 11, $first_mode);" "SELECT e3_insert(401, 12, $second_mode);" \
    ROLLBACK success 1
done <<'CASES'
true true 23505
true false 23P01
false true 23P01
CASES

query 'TRUNCATE assignments' >/dev/null
race 'concurrent/concurrent commits without waiting for first transaction' \
  'SELECT e3_insert(400, 11, false);' 'SELECT e3_insert(401, 12, false);' COMMIT coexist 2

for terminal in CANCELLED COMPLETED; do
  for finish in COMMIT ROLLBACK; do
    query 'TRUNCATE assignments' >/dev/null
    query 'SELECT e3_insert(400, 11, true)' >/dev/null
    expected=23P01
    [[ "$finish" == COMMIT ]] && expected=success
    race "$terminal $finish releases only after commit" \
      "UPDATE assignments SET status = '$terminal' WHERE id = e3_uuid(400);" \
      'SELECT e3_insert(401, 12, false);' "$finish" "$expected" 1
  done
done

# Down/up preserves operational values, keeps the old E1 index, and retains the
# shared extension. Use a baseline that can legitimately pass provenance again.
query 'TRUNCATE assignments' >/dev/null
query "SELECT e3_insert(500, 11, true); SELECT e3_insert(501, 12, false, 'CANCELLED')" >/dev/null
before=$(query "SELECT md5(jsonb_agg(jsonb_build_array(id, status, operator_exclusive) ORDER BY id)::text) FROM assignments")
"${psql_cmd[@]}" -q -d "$current_db" --single-transaction -f "$sql_dir/down.sql"
after=$(query "SELECT md5(jsonb_agg(jsonb_build_array(id, status, operator_exclusive) ORDER BY id)::text) FROM assignments")
[[ "$before" == "$after" ]] || { echo 'FAIL: down changed operational data' >&2; exit 1; }
[[ $(query "SELECT to_regclass('public.assignments_one_active_per_operator_index') IS NOT NULL AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'btree_gist')") == t ]] ||
  { echo 'FAIL: down removed E1 or shared extension' >&2; exit 1; }
"${psql_cmd[@]}" -q -d "$current_db" --single-transaction -f "$sql_dir/up.sql"
echo "PASS: migration down/up preserves assignment status and mode"
echo "E3 database acceptance passed: preflight, truth tables, identity, immutability, $race_counter concurrency cases, and down/up."
