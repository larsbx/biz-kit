# AgentCore delivery: reuse EventStore persistent subscriptions

Corrected after review: **EventStore already owns durable subscription delivery,
catch-up and checkpoints.** The earlier #166 draft duplicated that mechanism.
Its application cursor tables, cursor SQL functions and custom paging loop have
been removed before merge. No database objects are dropped by this correction;
the superseded migration was draft-only and must not be deployed.

## Existing machinery, verified in locked source

`mix.lock` pins `eventstore` 1.4.8. `CoopSubstrate.EventStore` already uses that
library. Its public `subscribe_to_stream/4` creates a persistent named
subscription by default, emits `{:events, recorded_events}`, and resumes its
stored checkpoint on reconnect. `ack/2` acknowledges successful processing;
`buffer_size` and `max_size` bound in-flight delivery and catch-up reads.
The library's subscription state machine serializes contiguous acknowledged
progress, stores it in its existing `subscriptions` table and handles replay
when notifications are missed. Its PostgreSQL advisory lock coordinates a
persistent subscription across consumers. No parallel event bus or cursor
manager is needed in `agent_ops`.

Subscribe to the canonical physical `"ledger"` stream, not `$all` or the
per-domain link streams. Its stream event number equals Log `global_seq` and
does not reconsume derived links as independent business facts. Each business
home's existing EventStore instance/database defines the authority boundary.

## Thin staging adapter

`CoopSubstrate.AgentEventSubscriber` is explicitly opt-in and staging-only; it
is not installed in any supervisor. It subscribes with a stable host-configured
name, `start_from: :origin`, `transient: false`, `buffer_size: 1`,
`concurrency_limit: 1`, `max_size: 100`, and `checkpoint_threshold: 1`.

One in-flight event prevents cumulative acknowledgment of an unregistered
item hidden earlier in a batch. Mailbox contents remain untrusted hints: the
adapter ignores supplied data, reads canonical bytes from Log, audits the
observed prefix against the appender head, verifies signature/schema and
registers the deterministic reconciliation effect or no-op receipt. Only after
the database call has committed does it call the EXISTING `EventStore.ack/2`.
Unexpected acknowledgments cannot advance the native subscription's in-flight
state. Unknown/uncommitted event numbers cannot create business authority.

`AgentEventDelivery` expresses this small application obligation with trusted
read/register/ack ports. It is not a subscription implementation. Migration 004
now creates only `agent_ops.event_effect_registrations`, containing immutable
effect identities/scope/hash or zero-effect processed receipts. It stores no
subscription resume position. The host registration role needs SELECT/INSERT,
not UPDATE/DELETE. Registration must use an ordinary dedicated host connection,
never an enclosing caller-owned transaction whose commit has not completed.

## Crash ordering and proof correspondence

| Boundary | Recovery |
| --- | --- |
| Crash before registration commits | No ack; native subscription redelivers |
| Registration commits, crash before ack | Native subscription redelivers; identical registration is idempotent |
| Ack/checkpoint fails or response is lost | A replay is safe because registration already committed |
| Ack/checkpoint succeeds | The effect receipt already exists |
| Duplicate or forged notification | Re-read canonical Log; native ack accepts only its own in-flight event; no launch authority comes from a message |

A separate effect-and-checkpoint SQL transaction is unnecessary for this
ordering: effects commit FIRST and the library checkpoint follows. A crash in
between causes duplicates, handled by stable effect identity. Do not directly
update the library's subscription tables. The cursor in the #162 abstract
protocol corresponds to the native EventStore checkpoint; `acknowledge` maps
to native `ack` after registration. This is an implementation correspondence,
not a machine-checked proof of the dependency or actual Elixir/SQL code.

## Acceptance and remaining limits

Local checks: two pure derivation tests and five delivery-order/crash-boundary
tests pass. The application compiles with warnings as errors. SQL migration and
receipt/privilege contracts are checked in PostgreSQL-in-WASM, which is not
native PostgreSQL concurrency or EventStore integration acceptance.

The dedicated signed-ledger CI now includes actual native subscription tests:
catch-up with no `:pg` subscriber, offline append and reconnect at the stored
checkpoint, subscription process death after registration/before ack, replay
without duplicate registration, next-event delivery after checkpointed ack,
failed registration without ack, forged hints and production refusal. Storage
CI retains independent PostgreSQL connection races for effect registration and
checks receipt persistence after Docker container recreation. Exact-head hosted
checks and the #162 proof gate remain required before merge; queued is not green.

These are discovery receipts, not execution leases or business facts. Fresh
signed task/grant state, approved profile, consent and PostgreSQL launch lease
checks remain in the existing Coordinator/Dispatcher. Backend idempotency,
external execution fencing, verified finality/absence receipts, secret isolation,
typed business-tool authority, automatic discovery draining and real distinct
backend acceptance remain in #92. The expensive prefix audit is staging-only
and needs optimization before high-volume release. No production activation,
agent framework choice, business writer or container dependency is added.
Docker/Podman-compatible storage remains; actual rootless Podman acceptance is
still a separate host check.
