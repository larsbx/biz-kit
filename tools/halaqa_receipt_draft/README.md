# Experimental PostgreSQL receipts and sender outbox

Date: 2026-11-01 (America/New_York).
Status: **Offline fixture host only; no production migration or receiver.**

This is an executable preparation for F3 in the
[federation boundary](../../docs/architecture/2026-10-31-halaqa-iroh-federation-boundary.md).
It follows the selected [PostgreSQL/Redis storage responsibilities](../../docs/architecture/2026-10-30-postgres-event-log-redis-consolidation.md).
It does not write the signed business history, Halaqa canonical events, financial
state, the existing discovery journal or any domain effect. Redis is not required
to retain or recover these receipts. No new application dependency is added.

## Binding and retained evidence

The immutable receipt key is `(recipient, sender, message_id)`. These are the
candidate's locally TEST-bound actor identities, not the Iroh endpoint key.
Epoch, charter, signing key and timestamps do not create a new replay namespace.
Identity succession and home/actor scope still need designated governing sources.

The binding covers the **exact original complete candidate bytes**, including
whitespace, not just the payload, parsed JSON, signature or outer serialization.
PostgreSQL derives SHA-256 from those bytes; receipt matching also compares the
bytes themselves. Re-signing an unchanged candidate returns the first receipt.
Changing even whitespace under the same key is a content conflict.

Receipts retain the first full candidate, full signed wire and explicit TEST
policy snapshot. The snapshot documents synthetic inputs at reception; it is
not current revocation, adoption or authority evidence. Conflicts retain the
full attempted candidate/wire/policy alongside the original receipt. Identical
conflict content is deduplicated by SHA-256, assuming collision resistance.
Later retries never overwrite original evidence. No expiry cleanup is supplied.

| Situation | Result | Durable change |
| --- | --- | --- |
| First verified candidate | `STORED_TEST_ONLY` | Original evidence and stable receipt ID |
| Same key and exact candidate, including a fresh signature | Original `STORED_TEST_ONLY` result | None |
| Same key and changed candidate | `CONTENT_CONFLICT` | Attempted evidence retained; original unchanged |
| Known key, matching hash status lookup | Original receipt | None |
| Known key, different hash status lookup | `CONTENT_MISMATCH` | None; lookup does not fabricate conflict evidence |
| Unknown key status lookup | `NOT_FOUND` | None |
| Invalid, expired or TEST-revoked new delivery | Verifier refusal | No database call |
| Transaction, storage or connection failure | No receipt returned; outcome may be unknown | Reconcile using original key/hash |

Every returned result has `authority_verified=false` and
`production_receiver=false`. A stored receipt acknowledges evidence retention,
not domain acceptance, a processed effect or settlement. Identity sequence
values may have gaps and are never complete replay watermarks.

## Transaction argument and interface

`ReceiptDraft.receive` loads the captured hash-verified Python reference bytes,
checks the draft-2 signature and external TEST bindings, then calls the narrow
SQL interface. Hex-encoded literals carry candidate, wire and policy into SQL;
neither a shell nor interpolated input syntax is used. The psql subprocess must
finish successfully after COMMIT before its JSON result can leave the adapter.
A SELECT result preceding a failed COMMIT is never an acknowledgement.

The unique receipt key serializes competing first inserts. `ON CONFLICT DO
NOTHING` waits for a conflicting transaction; the following PL/pgSQL command
reads the committed winner under READ COMMITTED. Equal bytes return that
winner; different bytes insert conflict evidence in the same transaction as
the returned conflict result. A rollback leaves neither a new receipt nor a
new conflict. No global ledger lock or remote call occurs in this transaction.
Repeatable-read/serializable transactions are refused by this experiment rather
than claiming an unimplemented retry contract.

`synchronous_commit=on`, `fsync=on` and `full_page_writes=on` are required.
This is a local-primary WAL durability profile, not synchronous replica,
disaster recovery, backup rollback or hardware power-loss certification.
Storage errors/timeouts fail closed. Capacity quotas and retention governance
remain pending; do not silently evict evidence to make space.

The schema revokes PUBLIC table/sequence/function access. A disposable test
client receives only the two reviewed functions; even the schema owner's normal
UPDATE/DELETE/TRUNCATE attempts hit append-only triggers. A privileged database
operator can alter/drop those protections: this is not cryptographic immutability.
`SECURITY DEFINER` routines fix their search path and qualify storage objects.
**SQL does not verify signatures.** Its caller is the trusted synthetic fixture
host. Do not grant these functions to an untrusted network-facing production
role or treat a client-supplied policy object as an authorization proof.

`status` is a local fixture operation. It can inspect retained results after
the original signature expires or a TEST pin changes, without re-admitting that
message. An eventual network status request needs fresh authenticated recipient
and actor scoping, disclosure policy and current permission checks. A fresh
signature on changed content can never replace the original ID binding.

## Sender custody and unknown-outcome recovery

`outbox.sql` installs after `schema.sql` in a fresh disposable database.
`tools/halaqa_outbox_draft.py` stages a locally verified signed fixture into an
immutable intent and its pending delivery row in one SQL transaction. Sender,
recipient and message ID bind the full original candidate, first signed wire
and TEST-policy snapshot. Re-signing that candidate at staging returns the
original wire; changed content retains a separate outbound conflict. Epoch,
charter and key changes never reset the ID namespace. No producer business
permission is inferred from staging a disclosed test signature.

| Previous state | Operation | Committed state |
| --- | --- | --- |
| Absent | Stage original intent and work row atomically | `PENDING_TEST_ONLY` |
| Pending or unknown | Begin attempt, increment generation | `UNKNOWN` before any peer callback |
| Unknown, matching generation | Fully bound stored receipt | `CONFIRMED_TEST_ONLY` |
| Unknown, matching generation | Bound remote original-ID/content mismatch | `REMOTE_CONFLICT` |
| Any state | Stale callback | State unchanged; `STALE_ATTEMPT` |
| Terminal | Begin again | Original terminal result; no peer call |

The unique intent key fixes one candidate. A row lock serializes attempts and
completion; the generation comparison prevents a late callback from overwriting
a newer attempt or terminal observation. A claim is not an expiring lease or
proof that a prior sender stopped. Concurrent workers can still transmit the
same original bytes: receiver replay handling remains necessary. This is an
implementation argument backed by tests, not a formal refinement proof.

`advance` always queries retained receiver status first. A fully matching
receipt can settle retention even after the old signature expires or its TEST
pin is revoked; this does not re-admit that message or confer permission.
Only a strict `NOT_FOUND` response permits considering transmission. The sender
then verifies the retained original wire against the **current** TEST policy,
and the receiver independently verifies against its own TEST policy. The
staging snapshot is not reused as a current clock/revocation source. Missing,
expired or revoked delivery stays `UNKNOWN`. An explicit retained-envelope
refresh/admission contract is still needed for expired unsent work; the harness
never silently re-signs or substitutes a new message ID.

Completion validates the reply schema, scoped actor/recipient/message tuple,
original candidate hash, positive int64 receiver receipt ID, exact fields and
literal false authority/production flags. A conflict must bind different remote
content under that same tuple; a content-conflict ACK must also bind attempted
content. Malformed, missing, unrelated or authority-amplifying responses cannot
settle an attempt. The selected full terminal reply is retained and cannot be
replaced through the operational interface. This is not an audit of every
failed/stale network response or a signed remote receipt protocol.

`LocalReceiptPeer` is an explicitly bound **in-process synthetic callback** with
its own local TEST policy. The acceptance harness uses two databases on one
PostgreSQL cluster; sender completion and receiver commit share no transaction.
There is no Iroh, HTTP, authenticated endpoint identity, fresh challenge-bound
status protocol or disclosure enforcement. JSON field checks do not authenticate
who issued an acknowledgement. Those are required before any live ingress.

The sender's pending/unknown pages come from durable SQL, scoped by sender and
recipient, with at most 16 results and a partial work index. A lost transient
wakeup does not erase intent or completion. These pages are not a complete
commit-prefix cursor: SQL sequence allocation can precede a later commit, and
each sweep must wrap back to zero to find late lower IDs. No Redis runtime or
scheduler is added, and actual Redis-loss/catch-up acceptance remains pending.

## Reproducible acceptance

Install PostgreSQL 16 server/client binaries and an Ed25519-capable OpenSSL CLI.
Run as an ordinary user permitted to create a child PostgreSQL process:

```sh
HALAQA_PG_BIN=/usr/lib/postgresql/16/bin \
  python3 -m unittest discover -s tools -p test_halaqa_receipt_draft.py -v
HALAQA_PG_BIN=/usr/lib/postgresql/16/bin \
  python3 -m unittest discover -s tools -p test_halaqa_outbox_draft.py -v
python3 -m unittest discover -s tools -p test_halaqa_federation_draft.py -v
```

The suite creates its own temporary cluster/database and test role, listens
only on a random loopback port, overrides inherited libpq connection settings,
and stops/removes that cluster at teardown. It never connects to an existing
user database. Trust authentication and disabled TLS are confined to this
isolated loopback test cluster. Do not copy that test setup into deployment.

Fourteen PostgreSQL integration tests cover independent backend races for equal
and changed bytes; full conflict retention; re-signing; recipient/actor isolation;
epoch reuse conflicts; rollback before receipt/conflict commit; server termination
after COMMIT but before a successful client return; immediate database stop/start
with WAL recovery; unavailability; expired/revoked new delivery versus retained
status; all 66 signed refusals stopping before SQL; role/immutability controls;
and unsupported durability/isolation settings. Sixteen sender tests additionally
cover atomic staging, first-byte custody, concurrent staging, current receiver
policy, strict negative status, stale callback fencing, scoped/bounded SQL work
pages, terminal immutability, lost receiver ACK after expiry, lost sender commit
ACK, unavailable/wrong peers and immediate database crash recovery of unknown
and terminal states. The 7 pin/mutation tests also pass: 37 Python tests total.

Local SQL acceptance ran on PostgreSQL 16.15. The restricted local environment
maps only uid 0, so a test-only libc ownership shim presented that mapped user as
an ordinary account to the unmodified binaries. It changed no I/O, fsync, clock
or SQL functions. Hosted CI runs the standard binaries as the runner user; that
exact-head evidence remains separate from this local result. Immediate server
termination tests crash recovery, not machine power loss.

## Remaining F3/F4 work

This slice provides a test receipt store, durable sender outbox and local
reconciliation interface. Next, bind these operations to authenticated bounded
Iroh streams and challenge-bound status requests, then exercise independently
administered direct/relay peers with application HTTP disabled. Redis scheduling,
actual key/charter/revocation sources, expired-envelope refresh, production
Elixir adapters, domain admission and effect execution remain pending.

Production receipt retention, access roles, capacity, home isolation, writer
fencing, failover/backup recovery and relationship to canonical admission require
review and actual adapters. No duplicate business ledger or external exactly-once
claim is introduced. Removing the disposable experiment changes no live state.

References: [PostgreSQL transaction isolation](https://www.postgresql.org/docs/16/transaction-iso.html),
[INSERT and ON CONFLICT](https://www.postgresql.org/docs/16/sql-insert.html),
[binary SHA-256](https://www.postgresql.org/docs/16/functions-binarystring.html),
[WAL durability settings](https://www.postgresql.org/docs/16/runtime-config-wal.html).
