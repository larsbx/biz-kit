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

**What is recorded.** One record per digest committed to a key (person,
project, task):

```
stream "evidence-quota":  EvidenceCommitted  {key, digest, bytes}
```

- **When.** Before the commit returns, the first time a write of that
  digest succeeds for that key. This includes a write proven to have landed
  after its worker died, as the quota already checked
  ([#33](https://github.com/larsbx/biz-kit/pull/33)).
- **Never.** A failed or refunded write leaves no record.

**On start.** The process folds the stream. Every recorded digest counts as
committed, once per key, wherever it was charged.

**A write in flight across a restart.** A reservation now names what it
charged: `{monitor, key, digest, bytes}`. If the write succeeds after the
process restarted, its commit reaches a process that never made that
reservation. The commit is still recorded and charged, so a write that
landed is never forgotten.

**What a restart loses.** Only reservations still in flight. Losing those
only makes room for writes that had not landed. A writer that dies after
writing but before committing, across a restart, is the one case in
which an extra copy of one file goes uncharged.

## Setup

`config :coop_substrate, event_stores:` now lists both stores, so
`mix event_store.create` and `mix event_store.init` create and initialise
both. The `records` schema is created in the same database.

- **Tests:** the alias drops the shared database once.
- **Production:** reads the same `EVENTSTORE_*` variables for both stores
  (`config/runtime.exs`).

## Verification

- **`ArtifactQuotaTest`** (*durable*), restarting the quota process as a
  node move or a cluster restart would:
  - committed files still count, and storing one again is held, not
    charged twice;
  - another key's room is its own;
  - a write reserved before a restart and committed after it is recorded,
    and still counts after a second restart;
  - failed and refunded writes leave nothing behind.

  The existing tests (concurrent writers, exceptions, worker death, keys
  per person, scope and task) still pass.
- **Mutation:** if a commit is not recorded, the restart test fails.
- **Browser (Chromium):** the evidence path is unchanged. It fills the
  quota and restores a file within it.

## Limits

- Records are never pruned. A key's records stay after its task ends,
  which is what keeps the quota from being reset by finishing a task.
- The rate limits are still in memory.
