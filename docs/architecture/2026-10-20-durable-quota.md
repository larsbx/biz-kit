# A durable evidence quota

Date: 2026-10-20. Status: **implemented**. Closes a limit of
[execution](2026-10-19-execution.md#limits): the evidence quota, at most
32 MiB per person per task, was counted only in memory. If its process
moved to another node, or the cluster restarted, counting started afresh,
and a person could store another 32 MiB.

## Decision

The quota (`ArtifactCustody.Quota`) records each charge it commits, and
rebuilds its counts from those records when it starts.

**Where the records live.** In `CoopSubstrate.Records`, a second event store:

- **Same database, own schema.** It uses the ledger's database, in a schema
  of its own (`records`). The ledger's store therefore keeps its rule that
  only `CoopSubstrate.Log` appends there.
- **Nothing ledger-like.** Nothing in `Records` is signed, chained or
  exported. A record is an Erlang term, read back with `:safe`
  (`Records.Serializer`), so a stored record cannot create atoms.

Three alternatives were rejected:
- **Not the ledger.** An upload is authenticated by session, not signed by
  a device, and the server signs nothing.
- **Not the custody receipts.** A file can be stored without a receipt ever
  being recorded, so counting receipts would let uploads escape the quota.
- **Not files beside the artifacts.** The artifact store is per node, and
  the quota's process may run on any node.

**What is recorded.** Every reservation, and how it settled, per key
(person, project, task):

```
stream "evidence-quota":
  {:reserved, id, key, digest, bytes, writer_node}   before charge/4 replies
  {:settled, id, committed?}                          before the settlement takes effect
  {:committed, key, digest, bytes}                    a success whose reservation was already settled
```

- **A digest is committed to a key** the first time a write of it
  succeeds. That includes a write proven to have landed after its worker
  died, as the quota already checked
  ([#33](https://github.com/larsbx/biz-kit/pull/33)).
- **A failed or refunded write** settles as not committed and gives its
  room back.

**On start.** The process folds the stream:
- Committed digests count, once per key.
- **Reservations still unsettled count too**, as pending. A full-limit
  upload in flight across a restart or a move to another node therefore
  still holds its room, and no second upload can take it while the first
  may yet land.

A restored reservation is settled by its writer's commit or refund. A
reservation now names its recorded ID and what it charged:
`{id, key, digest, bytes}`. If the writer never returns, then after a grace
period (`:quota_restore_grace_ms`, 60 s) the artifact on the writer's node
decides, as on worker death:
- found, or the node unknown or unreachable: the charge is kept;
- proven absent: the room is released.

A success that arrives after its reservation was settled that way is still
recorded and counted.

## Setup

`config :coop_substrate, event_stores:` now lists both stores, so
`mix event_store.create` and `mix event_store.init` create and initialise
both for development and tests. The test alias drops the shared database
once.

**Upgrading needs no manual step.** At application start, before the store
starts, `Records.setup!/0` creates the `records` schema and its tables if
they are missing, and is a no-op once they exist. It creates only the
schema, not the database, which is the ledger's and already there, so it
needs no right to create databases. Production reads the same
`EVENTSTORE_*` variables for both stores (`config/runtime.exs`).

## Verification

- **`ArtifactQuotaTest`** (*durable*), restarting the quota process as a
  node move or a cluster restart would:
  - committed files still count, and storing one again is held, not
    charged twice;
  - another key's room is its own;
  - a write reserved before a restart still holds its room after it, so a
    second full upload is refused; committed after the restart, it is
    recorded and still counts after a second restart;
  - refunded after the restart, it gives its room back;
  - a restored reservation nobody settles is resolved by the store: kept
    when the file is there, released when it is proven absent;
  - an installation without the `records` schema gains it from
    `setup!/0`, which is idempotent, and the quota then starts;
  - failed and refunded writes leave nothing behind.

  The existing tests (concurrent writers, exceptions, worker death, keys
  per person, scope and task) still pass.
- **Mutations:** if a commit is not recorded, the restart test fails; if a
  reservation is not recorded, the in-flight, restored and restart tests
  fail.
- **Browser (Chromium):** the evidence path is unchanged. It fills the
  quota and restores a file within it.

## Limits

- A writer still writing more than the grace period after a restart, whose
  file is not yet there when checked, has its room released. Its later
  success is still recorded, so the person can exceed the quota by that one
  file.
- Records are never pruned. A key's records stay after its task ends,
  which is what keeps the quota from being reset by finishing a task.
- The rate limits are still in memory.
