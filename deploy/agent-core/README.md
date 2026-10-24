# AgentCore storage: Docker **or** rootless Podman named volumes

This directory provides a **local development fixture**, not a new production
business database. The AgentCore execution contracts remain completely
independent of Docker, Podman, OpenShell, any agent framework or model vendor.

## What persists

One PostgreSQL 16 cluster sits on a **named volume**:
`bizkit-agent-pg16-data:/var/lib/postgresql/data`. The volume belongs
to the container engine and survives container recreation and normal
`compose down`. PostgreSQL provides durable transactions, row locks and
compare-and-swap semantics; **a volume by itself is not a transactional job
queue or a cross-node lock**.

The SQL migration `sql/001_agent_attempts.sql` creates
`agent_ops.execution_attempts` in **the existing PostgreSQL database**.
It stores operational run descriptors, lease epochs, expiry, hashed lease
tokens, immutable backend references, candidate digests and reconciliation
receipt references. It does NOT store prompts, private artifacts, plaintext
lease tokens, model credentials or an alternate signed business ledger.

Production uses the **existing biz-kit PostgreSQL server/database**, not this
separate local fixture. Its authoritative accepted task and run-intent facts
remain in CoopSubstrate. This standalone Compose fixture is deliberately
limited to storage development and is not the full Dispatch/PostGIS deployment.

## Start the same fixture using either engine

Create a local password file *outside the repository*:

```sh
mkdir -p "$HOME/.config/bizkit/secrets"
umask 077
openssl rand -base64 36 > "$HOME/.config/bizkit/secrets/agent-db-password"
export BIZKIT_PG_PASSWORD_FILE="$HOME/.config/bizkit/secrets/agent-db-password"
```

Choose **one** of the following with the same `compose.yaml`:

```sh
# Docker Compose
docker compose -f deploy/agent-core/compose.yaml up -d

# OR Podman Compose (a Compose provider must be installed)
podman compose -f deploy/agent-core/compose.yaml up -d
```

Do **not** start Docker and Podman against the same named-volume storage.
Named volumes are engine-managed, so Docker and Podman keep **different**
volume namespaces even when the declared volume name matches. Migrating
between engines requires a controlled database backup and restore, not
assuming that the container engines share the same files.

Initialize the operational schema (choose the same engine as above):

```sh
docker compose -f deploy/agent-core/compose.yaml exec -T db \
  psql -U bizkit -d bizkit_agent_dev -v ON_ERROR_STOP=1 \
  < deploy/agent-core/sql/001_agent_attempts.sql

docker compose -f deploy/agent-core/compose.yaml exec -T db \
  psql -U bizkit -d bizkit_agent_dev -v ON_ERROR_STOP=1 \
  < deploy/agent-core/sql/002_attempt_cas.sql

# Or replace 'docker' with 'podman'.
```

Postgres is bound only to `127.0.0.1:5544` on the host by default; set
`BIZKIT_AGENT_PG_PORT` if necessary. The password file is mounted into
the container as a Compose secret and used by the official Postgres
`POSTGRES_PASSWORD_FILE` convention. Podman's `podman compose` requires
an installed external Compose provider, such as `podman-compose` or
`docker-compose`, and support for Compose `secrets` in that provider;
validate the resolved service definition before first start.

## Transactional lease functions (staging contract)

`sql/002_attempt_cas.sql` defines **SECURITY INVOKER** PostgreSQL functions
for `claim_attempt`, `renew_attempt`, `attach_backend`,
`record_candidate`, `request_cancel`, `confirm_cancel_preverified` and
`reconcile_absent_preverified`. Every state change uses an expected
`row_version` predicate, atomic SQL `UPDATE ... RETURNING`, and
database-clock lease checks. A stale competing worker receives **zero
updated rows**, never an unconditional success.

Only a **trusted** coordinator service may execute these functions.
The migration revokes their default `PUBLIC` execution privileges; an
administrator must grant narrowly scoped execution to the coordinator role.
The functions **do not** validate signed business grants, tenant read access,
domain consent, provider policy, or external receipt signatures. Those are
hard prerequisites of the privileged calling host; never expose the SQL
entry points to agents, web clients or arbitrary plugins.

A lease token is supplied to the store as a SHA-256 digest, never persisted
in plaintext. A token must be generated with a CSPRNG and held in secret
operational state by the trusted host. Cancel and candidate operations clear
the stored token and lease. Expired leased rows are *not* claimable until a
privileged reconciler proves the backend absent and supplies a verified
receipt ID. An ID is provenance only: the SQL function itself cannot verify
its cryptographic validity, so the host must verify and bind it first.

`sql/ci_cas_contract.sql` exercises duplicate claim refusal, stale
version/token/epoch fencing, candidate state, cancellation and a
receipt-gated retry using a disposable CI database. These demonstrate
transactional database rules, **not** a live multi-node coordinator,
reconciler, service authorization, or external agent execution.

## Storage durability smoke

To verify that database content survives a container restart, after
initializing the schema:

```sh
docker compose -f deploy/agent-core/compose.yaml exec -T db \
  psql -U bizkit -d bizkit_agent_dev -v ON_ERROR_STOP=1 -c \
  "CREATE TABLE IF NOT EXISTS agent_ops.volume_probe (id text PRIMARY KEY);
   INSERT INTO agent_ops.volume_probe VALUES ('volume-ok')
   ON CONFLICT DO NOTHING;"

docker compose -f deploy/agent-core/compose.yaml restart db

docker compose -f deploy/agent-core/compose.yaml exec -T db \
  psql -U bizkit -d bizkit_agent_dev -v ON_ERROR_STOP=1 -c \
  "SELECT id FROM agent_ops.volume_probe WHERE id = 'volume-ok';"
```

For Podman, substitute `podman compose`. This checks *persistence*, not
lease concurrency, retry idempotency, backup recoverability, or production
migration parity.

`docker compose -f deploy/agent-core/compose.yaml down` (or the Podman
equivalent) stops/removes the service while **preserving the named volume**.
**Never use `down -v` or remove the volume to repair a start error**: that
deletes persistent database data. Use explicit backups and tested restores
before engine changes, upgrades or host migrations.

## Production requirements (still open)

- Apply the operational schema to the governed biz-kit database under
  a reviewed migration. Never create an independent source of business truth.
- Implement the persistent host adapter using transactions, atomic
  `row_version` checks and locked current-state transitions.
- Use PostgreSQL's authoritative clock for lease expiry; do not trust a
  worker-reported time, lease token or reconciler self-attestation.
- At least one running backend may exist after a network timeout. Before
  retrying, obtain a **verified** backend-absence or completed-result
  receipt, bound to the exact effect ID and immutable backend identity.
- Keep sandbox/agent scratch storage ephemeral and per run. Do not share
  arbitrary agent workspaces on this database volume.
- Use encrypted backups, access controls, retention and tested restore.
  Named volumes are **not backups**. A named volume is local to its host;
  multiple coordinator nodes must connect to one PostgreSQL service rather
  than sharing a host filesystem volume.
- Pin image digests for a production deployment and review volume layout
  before a PostgreSQL major upgrade. PostgreSQL 16 uses
  `/var/lib/postgresql/data`, whereas newer major versions may use
  different mount paths.

See [AgentCore architecture](../../docs/architecture/2026-10-24-signed-agent-runs.md),
[PR #103](https://github.com/larsbx/biz-kit/pull/103) and
[coordinator issue #92](https://github.com/larsbx/biz-kit/issues/92).
