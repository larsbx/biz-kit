#!/usr/bin/env bash
# Install / upgrade the biz-kit operations MVP (dev-mode `orchestration`
# release) on papa as a user service on 127.0.0.1:4001.
#   install-bizops-dev.sh <orchestration-release.tar.gz>
# Idempotent: keeps the env file, keys, databases and state across upgrades.
set -euo pipefail
tarball=$(readlink -f "$1")
base=$HOME/ops/bizops-dev
PGBIN=$HOME/data/pglocal19/bin
export LD_LIBRARY_PATH=$HOME/data/pglocal19/lib
psql() { "$PGBIN/psql" -h /tmp -p 5432 -U postgres -v ON_ERROR_STOP=1 -At "$@"; }

install -d -m700 "$base" "$base/keys" "$base/state"
umask 077

# --- databases: one role, three databases, nothing shared with the cluster's
# other tenants (spruce_goose_dev there belongs to the accountabot dashboard).
if [ ! -s "$base/db.password" ]; then
  python3 -c 'import secrets; print(secrets.token_hex(24))' > "$base/db.password"
fi
pw=$(cat "$base/db.password")
if [ "$(psql -d postgres -c "select 1 from pg_roles where rolname='bizops_dev'")" != 1 ]; then
  psql -d postgres -c "create role bizops_dev login password '$pw'"
else
  psql -d postgres -c "alter role bizops_dev login password '$pw'"
fi
for db in bizops_dev_eventstore bizops_dev_task_host bizops_dev_spruce_goose; do
  [ "$(psql -d postgres -c "select 1 from pg_database where datname='$db'")" = 1 ] \
    || psql -d postgres -c "create database $db owner bizops_dev"
done

# --- env file (secrets generated once) ---
if [ ! -s "$base/env" ]; then
  skb=$(python3 -c 'import secrets; print(secrets.token_urlsafe(64))')
  tss=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')
  principal=$(python3 -c 'import base64,secrets; print("prn_"+base64.b32encode(secrets.token_bytes(16)).decode().lower().rstrip("="))')
  cat > "$base/env" <<EOF
# biz-kit operations MVP, dev-mode release. Loopback only; dev sign-in.
EVENTSTORE_DATABASE=bizops_dev_eventstore
EVENTSTORE_USERNAME=bizops_dev
EVENTSTORE_PASSWORD=$pw
EVENTSTORE_HOST=127.0.0.1
EVENTSTORE_PORT=5432
TASK_HOST_DATABASE_URL=ecto://bizops_dev:$pw@127.0.0.1:5432/bizops_dev_task_host
SPRUCE_GOOSE_DATABASE_URL=ecto://bizops_dev:$pw@127.0.0.1:5432/bizops_dev_spruce_goose
TASK_HOST_SECRET_KEY_BASE=$skb
TOKEN_SIGNING_SECRET=$tss
SPRUCE_GOOSE_PUBLIC_URL=http://127.0.0.1:4001
BIZKIT_DEVELOPMENT_SIGN_IN=lars=lars
BIZKIT_IDENTITY_BINDINGS=[{"issuer":"biz-kit-development","subject":"lars","principal":"$principal"}]
TASK_HOST_OPERATIONS_CONFIG=$base/operations.json
HARNESS_KEYS_DIR=$base/keys
EOF
fi
[ -s "$base/operations.json" ] || cat > "$base/operations.json" <<'EOF'
{"schema_version": 1, "title": "Operations (dev)", "time_zone": "America/Detroit", "workspaces": []}
EOF

# --- release: unpack beside the old one, then swap ---
new=$base/release.new
rm -rf "$new" && mkdir -p "$new" && tar -xzf "$tarball" -C "$new"
[ -x "$new/bin/orchestration" ] || { echo "not an orchestration release"; exit 1; }
rm -rf "$base/release.old"
[ -d "$base/release" ] && mv "$base/release" "$base/release.old"
mv "$new" "$base/release"

# --- unit ---
install -d "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/bizops-dev.service" <<EOF
[Unit]
Description=biz-kit operations MVP (dev release, 127.0.0.1:4001)
After=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=exec
EnvironmentFile=$base/env
WorkingDirectory=$base/state
ExecStartPre=$base/release/bin/orchestration eval "SpruceGoose.ReleaseTasks.migrate()"
ExecStartPre=$base/release/bin/orchestration eval "TaskHost.ReleaseTasks.migrate()"
ExecStart=$base/release/bin/orchestration start
ExecStop=$base/release/bin/orchestration stop
Restart=on-failure
RestartSec=10
MemoryMax=1500M
TimeoutStartSec=300
OnFailure=failmail@%n.service

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable bizops-dev.service
systemctl --user restart bizops-dev.service
for _ in $(seq 60); do
  curl -s -o /dev/null -m2 http://127.0.0.1:4001/operations && break
  sleep 2
done
systemctl --user --no-pager status bizops-dev.service | head -5
curl -s -o /dev/null -w 'GET /operations -> %{http_code}\n' http://127.0.0.1:4001/operations
