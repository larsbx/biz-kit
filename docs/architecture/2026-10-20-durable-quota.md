# A durable evidence quota

Date: 2026-10-20. Status: **implemented; acceptance checks required before merge**.
The evidence quota is at most 32 MiB per person per task, including pending
uploads. Restarting quota accounting must not create more capacity.

## Operational records, separate from the signed ledger

`CoopSubstrate.Records` uses the ledger's database under the `records`
schema. Only `CoopSubstrate.Log` appends to `CoopSubstrate.EventStore`.
Operational records are neither signed nor chained nor exported as business
events. `Records.Serializer` decodes Erlang terms with `:safe`.

Neither custody receipts nor local artifact files can be the quota authority:
a successful upload can lack a receipt, and each node has its own files.
The cluster singleton folds the operational stream before admitting uploads.

```
stream "evidence-quota":
  {:reserved, id, key, digest, bytes, writer_node, writer_pid_binary}
  {:settled, id, committed?}
  {:committed, key, digest, bytes}
```

Reservation and settlement records are appended before their effects become
visible. Committed digests count once per key (person, project, task).
Concurrent reservations for one digest share its byte charge; releasing one
cannot erase another pending reservation or a successful write. Historical
`committed` records and six-element `reserved` records remain readable.

## Recovery without expiration

Unsettled reservations retain capacity after every restart. New records include
the writer PID encoded as bytes, including its VM creation identity. This avoids
introducing peer-node atoms while replaying records on another node. Recovery
asks the writer's node to decode and check its own PID:

- **Alive:** reattach a process monitor. The writer retains its capacity for as
  long as it runs, regardless of how long its upload takes.
- **Confirmed dead:** inspect the artifact on that node. Proven absence releases
  room; an existing, corrupt or unverifiable artifact conservatively commits the
  charge, as with worker-death recovery before this change.
- **Unreachable or unknown:** retain the pending reservation. Retry recovery
  after `:quota_recovery_retry_ms` (default 60 seconds). The timer retries a
  liveness check; it never expires capacity.
- **Distribution monitor reports `:noconnection`:** retain capacity and retry.
  A disconnected process can still be writing; disconnection is not death.
- **Legacy reservation without writer identity:** retain capacity until explicit
  commit or refund. Absence of a file cannot prove its writer has stopped.

A writer can commit or refund its existing reservation after restart. Successful
commit is idempotent by digest. A failed commit acknowledgement after successful
file I/O leaves the reservation in place for recovery; it does not run a failure
refund. A failed write or exception refunds its own reservation. The writer must
perform the file I/O synchronously; refund means it has stopped writing.

This replaces the original grace-period design, which could release capacity
before a slow writer created its file. That allowed another full-size upload
followed by an unchecked late commit. No timeout now authorizes that release.

## Production upgrade

Before starting `Records` or `Quota`, `CoopSubstrate.Application.start/2` calls
`Records.setup!/0`. It connects to the existing ledger database and acquires a
PostgreSQL transaction-level advisory lock dedicated to operational-store setup.
In that same transaction it checks for the records tables and, when absent,
creates the schema and runs EventStore's initializers. Independent cluster
nodes serialize on this database lock; check and DDL cannot race. Failure rolls
back and stops application startup before quota admission.

The database must already exist. No `CREATEDB` privilege is required. For the
first upgrade, the configured role needs `CREATE` on that database to create
the schema and objects. Subsequent starts only check the existing tables.
Administrators using a restricted runtime role can preinitialize the schema
with a suitably privileged role and grant the runtime role the EventStore
permissions before starting the release. No business ledger table is changed.

Production reads the same `EVENTSTORE_*` connection variables for both stores.
Development/test `event_stores:` lists both; the test alias drops their shared
database once, then creates and initializes both schemas.

## Regression coverage

`ArtifactQuotaTest` covers committed replay, digest idempotence, failed writes,
concurrent writers, and independent person/project/task keys. The new tests:

- Pause a real upload before file creation, restart quota, explicitly execute
  recovery, and attempt a competing full-limit upload. It must be rejected;
  the original can land and remains charged after another restart.
- Kill writers while quota is stopped, then restore accounting. Only absent
  bytes from a confirmed-dead writer are refunded; landed artifacts count.
- Restore a live writer's monitor and confirm later death releases absent bytes.
- Keep legacy or unreachable reservations across repeated recovery passes.
- Run an actual peer-node writer through restart and distribution disconnect;
  its capacity remains reserved, and its eventual success survives replay.

`RecordsUpgradeTest` stops the application against a database containing an
actual signed ledger event, removes only the operational schema, and boots the
production application. It verifies quota operation, unchanged ledger bytes,
head and signatures, and idempotent setup. A second regression launches eight
initializers together against a ledger-only database and then boots the app.

The CI formatting gate includes these files. Acceptance also requires the
existing umbrella compile, ledger/custody, cluster, identity, orchestration,
JavaScript, Chromium workflow, and Quint model checks. Test results belong in
the PR validation record; a local lifecycle adapter is not database validation.

## Limits

- Unknown or legacy writers may retain capacity indefinitely. This is a
  deliberate availability tradeoff: no automatic timeout can prove an
  outstanding write will never land. Do not manually release a reservation
  until its writer is stopped and the artifact's outcome is known.
- Records are not pruned. Finishing a task does not reset its quota.
- This change retains the existing cluster-singleton coordination model; it
  does not add database fencing for independently active quota processes in
  a split-brain cluster.
- Existing uploads made before durable accounting was deployed are not
  backfilled from unsigned receipts or per-node files.
- Rate limits remain in memory.
