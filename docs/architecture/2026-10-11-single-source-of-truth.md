# One source of truth for biz-kit

Date: 2026-10-11 (America/Chicago).
Direction: consolidate business-state authority. Status: **target architecture;
runtime consolidation remains to implement**.

This replaces the October 9 recommendation to retain independent authorities
behind adapters. The selected direction is one source of truth. The proposed
implementation uses the existing CoopSubstrate signed ledger as that source,
rather than building another persistence framework.

## Target

**One signed business-event ledger, one command admission path, one principal
registry, and one PostgreSQL database. Task, dispatch, ownership, and economic
views are rebuildable projections of accepted events.**

Keep domain logic organized in modules. Keel supplies pure structure and
ownership calculations; task and dispatch modules supply their own rules.
All accepted business changes enter the same ledger. A cache, job queue,
dashboard, or Ash resource cannot independently establish a competing fact.

| Concern | Common implementation |
| --- | --- |
| Durable business facts | Promote `CoopSubstrate.Log` and its existing `eventstore` backend to the platform ledger. Extend its typed event registry and append validation for the admitted domains. |
| Event bytes, signatures, and order | Existing `CoopEventCanonicalV1` profile, Ed25519 signer declarations, global/per-stream chains, and checkpoints. Global order is ledger acceptance order; effective time remains event data. |
| Writes | Domain commands validate against a committed ledger version; the serialized append gate rechecks authority and preconditions before accepting events. Acknowledge only after the append is durable. |
| Reads | Ash/PostgreSQL tables provide queryable projections. They can be rebuilt or replaced without changing business history. |
| Database/configuration | One database connection target and one deployment/migration contract. Isolate EventStore-owned tables from projection/job tables inside that database; consolidate projection Repos. |
| Identity | One platform principal registry and scoped grant model, derived from the ledger. Prefer the existing external OIDC entry point for authentication; retain separate token audiences and domain permission meanings. |

The existing ledger already has verify-on-append, atomic batches, exact-byte
storage, pure replay, and independent export. It uses the `eventstore` library
directly, without the full Commanded aggregate framework. That makes it the
strongest delivered starting point for consolidation ([substrate], [log],
[event-store]). This is a design choice based on that implementation, not a
claim that task or dispatch writes already use it.

## Remove competing authority and unused machinery

| Existing component | Consolidation action | Condition before removal |
| --- | --- | --- |
| AshEvents notes spike: `Notes`, `Events`, replay clearing, `ash_events` dependency | Retire the spike and its second event/replay mechanism. | Inventory any stored notes, preserve needed bytes/history, and verify no supported consumer depends on it. Source search finds the extension only on `Notes.Note`. |
| SpruceGoose PostgreSQL certified-event writer and `ShadowEvents` snapshot writes | Replace new business-event writes with typed events on the common ledger; stop the separate certified-event stream. | Migrate task, deployment, derivation outcome, grant, and other covered write paths. Preserve old ETF bytes and identities as historical evidence. |
| SpruceGoose live task-row authority and Dispatch direct domain writes | Convert mutations to commands and rows to projections. | A covered command cannot succeed via a row write or an old writer; ledger append failure changes no business state. |
| Per-app business outboxes and audit bridges | Derive delivery work from the accepted common ledger, with consumer cursors and stable effect IDs. | Durable delivery/retry replaces each current transport before its code is removed. Delivery accounting is operational state, not a second business log. |
| Duplicate principal/user/grant registries and local OAuth issuer | Introduce one governed principal-link/grant model and one authentication entry point. Retire redundant issuer/token machinery once clients migrate. | Preserve identity mappings, active grants, revocations, service/agent scopes, and MCP client authorization. Never merge users merely because names/emails match. |
| Duplicate projection Repos, migration owners, and production configuration | Consolidate projection ownership in one Repo and retain the existing EventStore backend in the same database. | Resolve conflicting `users`, `outbox_events`, and migration tables by explicit mappings, not by pointing today's Repos at the same schema. |
| Unused constitutional-kernel scaffold | Remove code with no delivered admission caller; retain the actual implemented domain checks. | Preserve immutable artifact/provenance bytes referenced by existing records. `Kernel.Constitution` currently has callers only in its own test. |

These are removal targets, not deletions performed by this documentation
change. The call sites and contracts are in [notes], [shadow], [pg-ledger],
[task-projector], [deployment-ledger], [derivation-executor], [dispatch-outbox],
[authorization], [constitution], and [runtime].

No permanent cross-ledger receipt bridge is part of the target. Temporary
comparison and migration tooling must have an explicit retirement condition.
Do not replace deleted scaffolding with a general integration framework.

## Keep the guarantees that make the one ledger useful

### Commands and projections

Introduce typed transition events rather than continuing whole-row snapshots
as the new task history. Record the principal, subject, action, input,
expected aggregate version, authorization references, applicable rule/artifact
versions, and admitted result/effect identity. Current SpruceGoose snapshots
cannot alone explain why a transition was licensed ([sg-decisions]).

The append gate must reject stale concurrent changes and revoked authority
using current ledger-derived state. A policy check against a lagging read
projection cannot license a write. Retain tenant and project scopes and the
existing domain refusal rules in the command admission path.

New task/dispatch types need explicit mappings from their tenant, project,
entity, and actor scopes to the ledger's chapter/stream and signer contracts.
Do not invent cooperative membership to make an operational event fit. If the
existing envelope cannot represent a required scope honestly, introduce a
reviewed forward protocol version; old events keep their original bytes and
verification rules. Large evidence stays in artifact custody with bounded
digest references, rather than in oversized event snapshots.

Projection updates may lag an append. Command replies identify the accepted
event and committed version; consumers needing read-after-write wait for that
watermark. Rebuilding projections performs no notifications, deployments, or
tool calls. A stopped projector affects query availability, not accepted truth.
Projector failure cannot make an already accepted event disappear.

Do not call the current EventStore API inside an Ash Repo transaction and
assume rollback is shared. They use different connections even when configured
for one database. The final path appends first, then projects; business-row
dual writes disappear. The test criterion is a rebuild from the ledger alone,
not agreement between two databases that both wrote the same snapshot.

External effects use stable IDs, retry/reconciliation, and explicit result
events. A durable dispatch/task intent is not proof that an external provider
performed its effect. Delivery must not turn replay into repeated execution.

### Signatures, identifiers, and identity

Keep original cooperative bytes and signatures valid. A platform service
signing an authenticated request attests its admission/observation; it must
not be described as the human requester's cryptographic signature. Preserve
the required bilateral signer semantics for existing economic events.

Ledger order replaces competing business-history orderings. Preserve existing
entity IDs and source mappings. `Identity.Local.next_seq()` currently reserves
non-reusable operation numbers, including numbers lost to rollback. A technical
allocator may remain in the common database; do not replace it with
`Log.head().global_seq + 1`, which reserves nothing. Sequence reservations and
committed event positions serve different purposes ([identity], [identity-local]).

Centralize authentication and principal linkage without unioning privileges.
Link `(issuer, subject)`, member signing keys, tenant participants, agents, and
OAuth clients to stable principals with explicit provenance. A membership or
login token does not automatically grant task or dispatch authority.
Replace the CLI's declared `--as` attribution with an authenticated principal
boundary before treating it as proof of caller identity ([oidc], [principal],
[authorization]).

The proposed authentication direction reuses Dispatch's external OIDC model.
Before retiring SpruceGoose's local OAuth server, verify that the chosen
provider supports the actual MCP client flows, resource/audience checks,
scopes, client bindings, and revocation contract. The existing local OAuth
server is not evidence of an interchangeable OIDC provider ([sg-oauth]).

One PostgreSQL database can retain separate technical roles for ledger append,
projection maintenance, and jobs. EventStore can retain its own connection
pool. These controls support the common authority; they are not separate
business sources of truth. Git holds reviewed rule/schema versions, and
artifact custody holds evidence bytes whose admission is recorded in the
ledger.

## Concrete implementation order

1. **Remove the unused notes/event spike first.** Inventory its data and consumers;
   remove unused resource/domain/dependency paths without dropping live tables.
   Preserve required historical bytes before retiring recovery readers.
2. **Deliver one ledger-backed task transition end to end.** Define its event and
   authorization schema, extend the existing append gate, add a pure fold, and
   make a fresh isolated instance execute the command and rebuild its view from
   the ledger alone. Do not begin by creating another live audit ledger.
3. **Migrate the complete orchestration write surface.** Cover hierarchy,
   definitions, tasks/TODOs, grants, approvals, deployment authorization, and
   outcome receipts. Use isolated dual-read comparison to establish parity;
   keep the existing operational authority until its writer is fenced.
4. **Move dispatch, Keel ownership, and shared principal facts onto the same
   path.** Preserve tenant/assignment semantics, temporal ownership, pre-emption,
   signer requirements, and optimistic preconditions. Consolidate database,
   projection Repo, migration ownership, and runtime configuration as each
   surface is made compatible.
5. **Finish cutover and delete the obsolete writers.** Once each admitted surface
   is covered and recoverable, retire its old row authority, local certified
   writer, dual-write hooks, business outboxes, duplicate issuer/registries, and
   unused framework code. Keep old event bytes and identities as read-only
   evidence. Optional truck-shop/spruce imports stay out of this work unless
   they supply a specific missing capability through the common admission path.

The first runtime PR should therefore remove the notes spike and implement a
bounded ledger-backed task command in an isolated instance. This document does
not claim that PR exists or those runtime steps have run.

## Cutover proof and completion

Capture a stable baseline with the old writer fenced, including legacy IDs,
exact source digests, mappings, and a verified replay boundary. A signed
baseline event acknowledges historical state; it does not invent signatures
or approvals for old rows. Preserve legacy ETF events and artifact IDs under
their original encodings. `Kernel.Canonical` also serves artifact identities,
so removing its use for new business events does not authorize changing every
existing content ID ([current-state], [canonical]).

For a migrated aggregate, exactly one writer is enabled. Forward commands use
the new path only after baseline parity, refusal checks, concurrency checks,
and crash/recovery checks pass. Short-lived comparison reads do not grant the
old writer continuing authority. Before new writes, a failed rehearsal can
return to the unchanged old path; after new authoritative writes, recovery
must include those events and writer fencing. Simply switching configuration
back would fork history.

Consolidation is complete when:

- every supported business mutation goes through the common append gate;
- old writers and duplicate event engines have been removed or fenced permanently;
- a clean projection schema reconstructs supported business state from the
  accepted baseline, preserved versioned artifacts, and common ledger;
- modified projection rows cannot license or commit a business change;
- duplicate requests, stale commands, revoked grants, projection lag, and
  restart after append/before response produce consistent results;
- task, dispatch, ownership, identity/grant, and economic recovery uses one
  event/version contract, with preserved signatures and scoped access.

The runtime currently remains at the imported architecture. Main was checked
again at `8aa79ec1ca419718d70592f15d8cf39bb271e32f`; the only open follow-up was
the documentation PR. The [October 9 comparison](2026-10-09-integration-decisions.md)
retains the source evidence and costs. Its multi-authority recommendation and
staged receipt-bridge path are superseded by this consolidation target.

[substrate]: ../../apps/coop_substrate/SUBSTRATE.md
[log]: ../../apps/coop_substrate/lib/coop_substrate/log.ex
[event-store]: ../../apps/coop_substrate/lib/coop_substrate/event_store.ex
[notes]: ../../apps/spruce_goose/lib/spruce_goose/notes/note.ex
[shadow]: ../../apps/spruce_goose/lib/spruce_goose/kernel/shadow_events.ex
[pg-ledger]: ../../apps/spruce_goose/lib/spruce_goose/kernel/postgres/event_ledger.ex
[task-projector]: ../../apps/spruce_goose/lib/spruce_goose/kernel/task_projector.ex
[deployment-ledger]: ../../apps/spruce_goose/lib/spruce_goose/deployment/ledger.ex
[derivation-executor]: ../../apps/spruce_goose/lib/spruce_goose/derivations/executor.ex
[dispatch-outbox]: ../../apps/dispatch/lib/dispatch/outbox/publisher.ex
[authorization]: ../../apps/spruce_goose/docs/authorization.md
[constitution]: ../../apps/spruce_goose/lib/spruce_goose/kernel/constitution.ex
[runtime]: ../../config/runtime.exs
[sg-decisions]: ../../apps/spruce_goose/docs/decisions/2026-09-08-kernel-and-ledger-shape.md
[identity]: ../../apps/spruce_goose/lib/spruce_goose/identity.ex
[identity-local]: ../../apps/spruce_goose/lib/spruce_goose/identity/local.ex
[oidc]: ../../apps/dispatch/lib/dispatch/identity/tokens/oidc.ex
[principal]: ../../apps/dispatch/lib/dispatch/identity/principal_resolution.ex
[sg-oauth]: ../../apps/spruce_goose/lib/spruce_goose/oauth2_server.ex
[current-state]: ../../apps/spruce_goose/docs/current-state.md
[canonical]: ../../apps/spruce_goose/lib/spruce_goose/kernel/canonical.ex
