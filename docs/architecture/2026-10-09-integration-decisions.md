# Integration decision matrix and staged path

Date: 2026-10-09 (America/New_York). Status: **recommendations for review**.

This review is anchored to merged biz-kit commit
`8aa79ec1ca419718d70592f15d8cf39bb271e32f` ([integration PR #1][integration-pr]).
It changes documentation only. Proposed settings, adapters, event types, and
cutovers below are not implemented or authorized by this document.
Source inspection establishes repository behavior and documented contracts;
it does not establish the state of a running deployment. In particular,
SpruceGoose's `current-state.md` carries its own dated production evidence.

## Recommendation

Retain independent domain authorities with explicit adapters. Share the build,
dependency review, deployment inventory, observability, and selected backing
infrastructure. Make production configuration and database isolation the first
implementation follow-up. Treat common event storage or token implementations
as later, evidence-gated choices.

The contracts that need agreement are cross-application identities, event
meaning, ordering, retries, authority, and configuration ownership. Equal table
layouts, login libraries, and persistence engines are not prerequisites.
CoopSubstrate's ONE canonical log requirement governs cooperative ledger truth;
it does not make dispatch's operational rows or SpruceGoose's task rows competing
cooperative ledgers ([substrate], [dispatch-readme], [authority-planes]).

## What the implementations actually contain

The README's “eventstore versus ash_events” item is an incomplete description
of the integration boundary. `eventstore` is used directly; full Commanded
aggregates and command handlers were not adopted ([substrate], [coop-mix]).
SpruceGoose has both a small AshEvents notes domain and a separate certified
event ledger for orchestration shadow history ([notes], [ash-event], [shadow]).

| Component | Delivered contract and advantages | Limitations and integration consequence |
| --- | --- | --- |
| CoopSubstrate `Log` / `eventstore` | Stores canonical CBOR-profile bytes verbatim; validates schemas, signatures, and log-dependent validity before an atomic batch append. One physical `ledger` stream assigns the global chain; derived stream links support selective reads. Pure folds, export verification, and checkpoints support reproducible economic records. | One serialized appender is a throughput and availability constraint. Stream links can lag and are repaired on restart. New integration events need reviewed types, signer roles, and validity rules; arbitrary Ash changes are not accepted ledger events. ([substrate], [coop-log], [types], [validity]) |
| SpruceGoose PostgreSQL `certified_events` | Immutable rows, exact SHA-256 content identities, ordered stream positions, and conflict-safe idempotency. Supported shadowed mutations and their candidate events commit in the same Repo transaction. | Kernel bytes use pinned deterministic Erlang External Term Format, not CoopEventCanonicalV1; content hashing is not Ed25519 author attestation. Task shadow payloads contain snapshots. Root checks validate shape, not artifact resolution. This is not a completed historical-authority cutover. ([certified], [canonical], [pg-ledger], [shadow], [current-state]) |
| SpruceGoose AshEvents | Captures and replays `Notes.Note` resource actions with little domain plumbing. The imported lock pins AshEvents 0.7.0. | Only `Note` declares `AshEvents.Events`; it is not the task ledger. Notes replay clears notes and requires explicit enablement. The retained substrate spike found missing native per-stream sequencing and action-dependent replay; that historical result is not a blanket assessment of every later AshEvents release. ([notes], [ash-event], [clear-notes], [substrate], [lock]) |
| Operational rows and outboxes | Dispatch owns dispatch state; SpruceGoose owns live orchestration state. Transactional outboxes separate commit from notification/delivery. | Delivery is not a transfer of authority. SpruceGoose delivery is opt-in and at-least-once. Dispatch's publisher targets local SSE PubSub and consumers rebuild authorized snapshots; it is not an external durable ledger bridge. ([dispatch-readme], [dispatch-outbox], [outbox-delivery]) |

Cooperative authors sign the **core**, including content and the ordered signer
declarations. The log subsequently assigns sequence and predecessor fields.
`event_hash` covers the full canonical record, including signatures and chain
fields; checkpoint keys sign chain heads. Authors therefore attest content,
while the log commits its placement. A CBOR receipt for a SpruceGoose event
would attest the adapter's observation; it would not retroactively make the
original ETF event author-signed or independently replayable ([substrate],
[envelope], [coop-log]).

Neither database triggers nor hash chains prevent a privileged operator from
rewriting an entire unanchored history. Independently retained signed
checkpoints constrain that threat for the cooperative ledger; deployment
roles, key custody, and external evidence remain part of the trust boundary.

## Authority boundaries

| Fact or decision | Authority retained | Permitted integration role |
| --- | --- | --- |
| Cooperative membership, registered signing keys, capital and economic records | CoopSubstrate signed canonical ledger and its append gate | Other apps consume verified events/projections; they do not overwrite ledger-derived balances. |
| Trips, loads, participants, operational role assignments | Dispatch's authorized domain actions and database | Orchestration submits scoped requests and observes results through adapters; it does not write Dispatch tables. |
| Task admission, lifecycle, grants, receipts and deployment authorization | SpruceGoose's governed Ash/PostgreSQL paths | The shared ledger may record typed audit receipts. A receipt cannot start a task or authorize a deployment. |
| Company structure and ownership calculation | Keel pure functions and invariants; Keel itself has no durable writer | A proposed ledger adapter would record licensed ownership transitions, with a Keel fold deriving the resulting structure. |
| Dashboards, joins, integration caches | No independent mutation authority | Rebuildable, access-filtered projections with source identities and watermarks. |

This map follows the imported contracts ([substrate], [dispatch-readme],
[current-state], [keel-readme], [ownership]). SpruceGoose's authority-planes
document describes a target in which mutable rows become projections.
Its current-state document and September decisions explicitly retain live row
authority and leave stream shape, root semantics, and kernel disposition open.
This review does not settle those decisions ([authority-planes], [current-state],
[sg-decisions]). Git definitions, historical events, evidence artifacts, and
projections also retain their separate authority roles.

## Integration strategies: decision matrix

Cost labels below are relative engineering estimates from the inspected
contracts, not measured budgets or performance results. “Separate” refers to
domain contracts; the apps already share a Mix umbrella, lock, and release.

| Dimension | Retain systems with adapters | Share selected infrastructure | Migrate to common implementations |
| --- | --- | --- | --- |
| Event ordering | Preserve source stream/revision order and add causal references. Cross-source total order is absent. | A common audit ledger orders receipt acceptance; source occurrence order remains separate. | Can simplify one newly defined ordering contract, but requires reconciling stream partitioning, rollback gaps, and concurrency. |
| Canonical signatures | Preserve each source's bytes and trust claims; bridge receipts have explicit signers. | Share verification/custody tooling where contracts match. Keep canonical profiles and signing purposes distinct. | A common future codec can ease independent tooling; re-encoding old records invalidates existing identities/signatures. |
| Replay | Keep CoopSubstrate pure folds, SpruceGoose snapshot/baseline replay, and notes action replay distinct. | Share replay reporting and artifact retention. Run rebuilds in isolated stores. | One replay API is attractive; moving Ash authority requires new transitions, coverage, parity, and effect isolation. |
| Authority | Clear single writer for each fact; eventual consistency must be visible. | Shared hosts or a ledger do not confer domain authorization. | Fewer stores may simplify transactions, but an accidental authority transfer can bypass existing policies and append gates. |
| Authentication | Retain OIDC resource-server validation and SpruceGoose OAuth/token handling. Explicitly map principals. | Federation can share interactive login while keeping audience, scope, actor resolution, and revocation local. | Fewer credential systems, but client flows, token semantics, grants, and recovery procedures must be migrated. |
| Database isolation | Separate databases and credentials give clear migration ownership and restore boundaries. | One PostgreSQL cluster with separate databases reduces infrastructure count; shares outage and capacity risk. | One schema/Repo enables local transactions only after model reconciliation; overlapping tables and migration histories prevent a safe drop-in merge. |
| Migration cost | Low initially, medium for robust delivery and mappings; preserves accumulated contracts. | Medium for namespaced runtime configuration, role isolation, sizing, and coordinated restore/runbooks. | High: data mappings, codec epochs, credential reissue, historical validation, cutover, and consumer changes. |
| Operational complexity | Multiple pools, adapters, lag checks, and source-specific recovery. | Central monitoring/build reduces duplication; a shared release couples restart, dependency, and secret exposure boundaries. | Fewer nominal components, but the common implementation inherits all prior guarantees and has a larger blast radius. |
| Failure behavior | Source operations can survive a bridge outage; pending/failed audit delivery must be visible. | Shared infrastructure introduces correlated failure; do not silently make optional audit delivery a task-admission dependency. | A common authoritative store can create a platform-wide admission outage. |
| Reversibility | Disable the bridge, retain cursors/receipts, rebuild projections; sources remain intact. | Separate databases can move hosts; schema separation and common release coupling cost more to unwind. | Reversibility falls sharply after new authoritative writes, token revocation, or changed historical encodings. |
| Recommendation | **Default integration model.** | **Adopt selectively after isolation checks.** | **Defer authority and persistence migrations; evaluate a concrete vertical slice first.** |

The ordering/replay and isolation assessments derive from [substrate],
[coop-log], [pg-ledger], [sg-decisions], [runtime], and the two user/outbox schemas
([dispatch-user], [sg-user], [dispatch-outbox-schema], [sg-outbox-schema]).
Authentication consequences derive from [oidc], [principal], [sg-oauth],
[actor-plug], and [authorization].

### Component recommendations

| Choice | Recommendation and reason | Cost, operational consequence, and reconsideration gate |
| --- | --- | --- |
| Commanded `eventstore` vs AshEvents | Keep the cooperative ledger on `eventstore`. Retain AshEvents for its current notes scope; do not make it the cooperative ledger merely to match Ash. | Low migration cost now; two distinct replay mechanisms remain. Reconsider only against a version-pinned acceptance suite covering exact bytes, signatures, atomic batches, chains, pure replay, and independent export. |
| SpruceGoose certified history | Preserve its local transactional shadow ledger and current live authority. Explore an audit-receipt bridge before an EventLedger replacement. | Medium bridge cost. Remote append inside an Ash transaction is not a shared transaction with EventStore. Replacement must first preserve all-or-nothing mutation/event behavior and settle SpruceGoose's open stream/payload decisions. |
| Authentication | Keep existing verifiers and token stores. Standardize principal-link and delegation contracts; trial shared login later if it solves a real user flow. | Medium mapping/federation cost; token and authorization migration is high. A shared dependency version is already agreed, not a shared identity model. |
| Production configuration/database | Agree one namespaced configuration contract, while retaining separate Repos, databases, credentials, migrations, and pool budgets. | Medium, immediate priority. Same cluster is optional. Separate schemas in one database are a fallback requiring explicit prefixes, migration tables, privileges, extension ownership, and restore rehearsal. |
| Keel ownership | Keep Keel pure. Add a versioned command-to-ledger boundary and a replayable ownership projection as a separately reviewed implementation. | Medium/high domain work: signer authority, eligibility, mandates, pre-emption, temporal intervals, and asset partition must be specified, not inferred from a struct. |
| Optional truck-shop | Keep outside the core release initially. Evaluate maintenance/parts/service-history capability through an adapter with an explicit vehicle/tenant identity map. | High immediate import cost: Phoenix/LiveView and authentication constraints differ. Its schema tenancy differs from Dispatch's attribute tenancy; fleet and assignment authorities must not be duplicated. |
| Optional spruce | Evaluate as an effect/runtime provider behind SpruceGoose's existing provider-neutral runtime-state port. Keep task and deployment authorization in SpruceGoose. | Medium/high hardening cost. It is documented as a scaffold, with policy/budget admission gaps. A process loop or durable agent row is not task authority. |

Evidence for the last three rows is [keel-readme], [ownership], [primitives],
[truck-mix], [truck-tenancy], [truck-model], [work-order], [vehicle],
[spruce-readme], [spruce-agent], [spruce-runtime], and [current-state].

## Required integration contracts

### Ordering, receipts, and replay

A proposed bridge should carry a versioned source-system/instance identity,
source event ID, stream and position or aggregate revision, source codec and
payload digest, causal parent IDs, and the bridge's own receipt identity.
Source occurrence time and receipt acceptance time are distinct. Do not sort
cooperative events by timestamp, UUID/ULID appearance, or outbox arrival time.
CoopSubstrate `global_seq`, SpruceGoose `stream_position`, and
SpruceGoose `origin_seq` are different contracts ([substrate], [pg-ledger],
[identity]).

Preserve opaque original bytes and their codec/digest when bridging certified
ETF events. Use a reviewed CoopSubstrate envelope to attest receipt and link
the source evidence; do not re-encode the source and claim byte/signature
equivalence. A receipt's position establishes when the ledger accepted it,
not when another database committed a task change. Preserve source revisions
and causal links; detect gaps and quarantine conflicting retries.
Large or confidential source bytes should stay in access-controlled artifact
custody, with their exact digest and codec in a bounded receipt. CoopSubstrate's
current canonical-size cap also rules out assuming every task snapshot fits
inline ([substrate]).

Bridge delivery needs durable intent, deduplication by source identity, and
content comparison on retry. A repeated source identity with different bytes
is a conflict. Persist the source-to-receipt mapping and cursor together in
the bridge's chosen store. CoopSubstrate currently rejects duplicate event IDs
rather than returning idempotent success: a crash after append but before
acknowledgment needs verified lookup/reconciliation, not a fresh receipt ID
([coop-log], [outbox-delivery]). Do not repurpose Dispatch's SSE publication
flag as an independent ledger-delivery acknowledgment ([dispatch-outbox]).

Rebuild integration projections without invoking live task actions, payments,
notifications, deployments, or tool execution. Expose source watermarks,
pending/failed receipts, and freshness in joint views. A reconciled projection
can report state; it cannot grant rights. Whitelist and minimize exported
fields under each source's authorization/disclosure rules; a shared ledger
must not turn task secrets or tenant data into cooperative public records
([substrate], [authorization], [principal]).

### Peer identity is separate from login identity

`SpruceGoose.Identity` identifies the originating peer with a 32-byte Ed25519
public key and allocates a never-reused operation counter. Today its only
adapter is `Identity.Local`, with a PostgreSQL `nextval()` sequence and retained
keypair. Its cooperation-log adapter is a design seam, not delivered code.
The key seed is currently stored in its database; external custody remains a
documented gap ([identity], [identity-local], [identity-tests]).

Keep the existing adapter initially. Do not replace `next_seq()` with
`Log.head().global_seq + 1`: it does not reserve a value, and rejected appends
would permit reuse. A future adapter must preserve the existing peer key and
IDs, advance beyond every issued counter including rolled-back operations,
and prove concurrent reservation, restart/crash behavior, and restore fencing.
A stale database restore must not mint again under the same peer/counter
namespace. Reserved operation numbers and committed ledger positions need not
be equal. Identifiers already minted remain unchanged ([identity-local],
[identifier-model], [coop-log]).

### Authentication and authorization

Dispatch is an OIDC **resource server**: clients use the external provider's
Authorization Code/PKCE flow, and Dispatch checks asymmetric signature,
issuer, audience, expiration, and nonempty subject. Its key cache has bounded,
serialized refresh. Local lookup uses `oidc_subject` under one configured
issuer, then chooses one active tenant role assignment and refuses ambiguity;
it does not union permissions ([oidc], [principal], [dispatch-user]).

SpruceGoose operates an Ash Authentication token store and OAuth server.
Authentication requires token presence; MCP actor resolution uses the verified
OAuth `client_id` through administrator-configured actor-ID bindings and the
`mcp` scope. That differs from Dispatch's person/tenant assignment. The local
CLI's `--as` is declared attribution behind an owner-only socket, not proof of
which same-UID process is calling ([sg-user], [sg-token], [sg-oauth],
[actor-plug], [authorization]).

Agree explicit mappings between external `(issuer, subject)`, local user,
tenant participant, SpruceGoose actor, OAuth client, and cooperative member/key.
These are distinct identities with distinct grants. Never link by email or
display name alone, and never treat an Ed25519 peer key as a user's login.
Multi-issuer support would require a versioned change to Dispatch's
subject-only identity, not merely accepting another issuer.

If common login is useful, keep tokens audience-bound and authorization local.
Do not assume SpruceGoose's OAuth server implements the external OIDC contract
Dispatch requires. Evaluate external login/federation or a deliberate token
exchange in a test realm first, with wrong-audience, expired/revoked-token,
unbound-client, disabled-actor, and cross-tenant refusal checks. Preserve
client IDs, grants, token revocation, and recovery procedures. Token revocation
or credential reissue cannot be undone by restoring a configuration file.
Sharing a login issuer also shares its availability and key-compromise risk;
retain per-service audience and key-rotation/refusal checks.

### Production isolation

The root release starts all four apps permanently. Root runtime configuration
reads `DATABASE_URL` and `POOL_SIZE` for both Dispatch and SpruceGoose, and
`SECRET_KEY_BASE` for both endpoints when MCP is enabled. Dispatch binds port
4000 by default on a wildcard address; MCP is opt-in, loopback-only, and also
defaults to 4000. These bindings can conflict ([root-mix], [runtime]).

Sharing one public database schema also collides on `users` and `outbox_events`,
not just `schema_migrations`. Distinct migration table names alone would not
resolve those collisions ([dispatch-user], [sg-user], [dispatch-outbox-schema],
[sg-outbox-schema]).

| Configuration contract to agree | Proposed setting names / boundary |
| --- | --- |
| Application databases | `DISPATCH_DATABASE_URL`, `SPRUCE_GOOSE_DATABASE_URL`; separate database and login role per authority |
| Connection budgets | `DISPATCH_POOL_SIZE`, `SPRUCE_GOOSE_POOL_SIZE`; separate EventStore budget and aggregate cluster connection limit |
| Phoenix signing secrets | `DISPATCH_SECRET_KEY_BASE`, `SPRUCE_GOOSE_SECRET_KEY_BASE`; no shared secret by default |
| Listeners | `DISPATCH_PORT`, `SPRUCE_GOOSE_MCP_PORT`; distinct listeners while preserving MCP loopback/opt-in and CLI socket permissions |
| Token/OAuth secrets | SpruceGoose-specific settings, separate from Phoenix secrets and cooperative Ed25519 custody |
| Cooperative EventStore | Explicit runtime database, credentials, TLS, pool, and initialization ownership; a production deployment contract is still needed |

These are **proposed names, not supported variables at this baseline**.
CoopSubstrate credentials currently enter its application config; its production
file explicitly leaves runtime credentials to a future deployment
([coop-config], [coop-prod]). Roll out namespaced variables with an explicit,
temporary compatibility policy and reject ambiguous shared fallback values.
Rehearse fresh migration and restore for each store before a joint production
boot; never initialize against an existing live authority by guesswork.

Share cluster administration, backups, metrics, and dependency maintenance
where useful. Retain separate migration owners, restore plans, job tables,
and signing credentials. Schema/database roles protect accidental access;
one BEAM release still holds the participating credentials, so it is not a
strong process isolation boundary. Separate release profiles/processes are a
later option for independent restart, scaling, or stricter trust separation.
Neither a common cluster nor umbrella-local calls make EventStore append and
an Ash Repo transaction atomic across stores.

### Keel ownership into the cooperative ledger

Keel operations return immutable structure/results; they do not commit a
business fact. Its exact rational shares, temporal stakes, withdrawal,
transfer, pre-emption, and dissolution semantics must survive integration
([ownership], [primitives]). No Keel ownership adapter or corresponding
ownership-event family was found in the imported CoopSubstrate registry
([types]).

A proposed command boundary should read the ledger-derived structure at a
named version, apply the appropriate Keel function, validate signer/mandate
authority, and append a typed signed transition. Specify entity/class/party
mapping, effective date versus append order, units and exact rational tuple
encoding, required signer roles, preconditions, Keel rule version, and causal
authorization references. Keel uses Elixir dates, atoms, structs, and possibly
rational tuples; convert them through a versioned schema rather than passing
them directly to the frozen CBOR profile.

The append gate must reject stale structure and recompute/check the licensed
transition against the current projection. Keel validation before append
alone cannot prevent two concurrent transfers spending the same holding.
Commit the ledger before acknowledging ownership; treat any structure cache
as a projection. Replay needs the pinned rule implementation/artifact and an
explicit baseline, not retrospective invented signatures. Withdrawal and
dissolution do not imply off-platform money movement occurred. Compensations
are new licensed events, never edits to history ([coop-log], [validity],
[coop-readme]).

## Optional application boundaries

Truck-shop offers maintenance work orders, service records, and parts, but
also fleet/driver assignments that overlap Dispatch. Its `Truck` and
`WorkOrder` use schema-context tenancy, while Dispatch's `Vehicle` uses
attribute tenancy. Define explicit cross-system tenant/vehicle mappings;
retain a single owner for each status or assignment fact. Prototype a
maintenance-availability adapter before deciding whether to import code.
Truck-shop's Phoenix `~> 1.7.11`, LiveView `~> 0.20.2`, and Ash Authentication
`~> 4.0` conflict with the umbrella's locked 1.8/1.2/5.0-rc versions; its
Elixir `~> 1.16` declaration alone is not evidence of incompatibility with
1.19. Admission requires dependency reconciliation and tenant/authorization
regression evidence ([truck-mix], [truck-model], [work-order], [vehicle], [lock]).

Spruce is an agent execution platform: a GenServer per agent, Ash turn
transitions, Oban for long tools, and selectable turn-history persistence.
That complements orchestration if it reports through SpruceGoose's runtime
port. Its README explicitly calls it a scaffold with unwired policy/budget
gates. Preserve the distinction between an execution turn and a governed
task. A runtime-provider trial needs effect admission, bounded budgets,
restart/completion reconciliation, and provenance; importing it must not
introduce a second task/deployment authority ([spruce-readme], [spruce-agent],
[spruce-runtime], [spruce-persistence], [current-state]).

## Staged path and acceptance gates

Each stage is a proposed follow-up, not evidence it has been completed.
Later authority changes require an explicit reviewed decision and deployment
authorization. Numeric SLOs and observation windows should be selected from
measurements; none are invented here.

| Stage | Concrete contribution | Exit evidence | Stop/rollback boundary |
| --- | --- | --- | --- |
| 0 — Contract inventory | Review this matrix; retain imported history and unresolved SpruceGoose decisions. Inventory deployment authorities and source identities. | Agreed fact owners and implementation scope; no claim that repository tests certify a running joint deployment. | Documentation remains revisable; no authority changes. |
| 1 — Configuration isolation | Separate runtime names, databases/roles, pool budgets, listener ports, secrets, migration ownership, and restore runbooks. | Joint release boots in an isolated production-like environment; schema separation and wrong-DB refusal checked; each store migrates/restores independently; secrets remain redacted. | Retain previous deployable artifact/config until rehearsal passes. Any data moved needs its own validated restore/cutover plan. |
| 2 — Receipt bridge in shadow mode | Build one typed SpruceGoose-to-cooperative audit adapter plus a read-only integration projection. Preserve source bytes and identities; add durable dedup/cursors and disclosure policy. | Crash after append/before acknowledgment, duplicate/conflicting delivery, out-of-order receipt, missing revision, invalid signature, and restart recovery handled. Independent receipt verification and source/projection reconciliation pass. | Disable delivery and retain pending records/cursors; do not delete signed receipts or alter task authority. |
| 3 — Keel vertical slice | Implement one ownership operation with reviewed event/signing schema, append-gate validation, and a pinned pure projection; expand only after that slice passes. | Golden bytes, authorized/unauthorized signers, competing stale transfers, eligibility/pre-emption, and replay/as-of results agree with Keel. Historical baseline explicit. | No live ownership writes until accepted. After activation, corrections are new authorized events; configuration rollback cannot erase committed transfers. |
| 4 — Shared identity experience | Establish governed principal links and test common login/federation if a concrete workflow needs it. Trial any peer-counter adapter separately. | Audience/scope/refusal matrix, tenant/actor/grant parity, revocation behavior, and client recovery pass. Counter adapter proves non-reuse and unchanged IDs. | Stop federation and retain original authorities. Revoked tokens and externally committed identity changes require explicit repair. |
| 5 — Selective consolidation | Measure bridge lag, ledger throughput/lock contention, pool use, recovery time, and support burden. Trial optional providers in isolation. | A concrete reduction in cost or capability gap justifies each common implementation; accepted transition/root semantics, dual-read parity, offline replay, canary, and recovery proof precede historical-authority migration. | Version new protocols; preserve old bytes, histories, keys, and source mappings. Fence writers before any authority transfer; no implicit dual masters. |

A future shared EventLedger could be worthwhile if it preserves every source
contract and simplifies a measured problem. The current evidence supports
adapters and infrastructure isolation first; it does not support rewriting
existing cooperative signatures, reminting peer IDs, or importing optional
apps as an immediate architectural prerequisite.

## Evidence and review limits

The supplied upstream READMEs were read alongside the imported source. Core
recommendations use the biz-kit baseline; upstream context does not silently
update the imported applications. Optional applications were inspected at
the revisions below and remain outside biz-kit.

| Repository | Reviewed revision | Context |
| --- | --- | --- |
| biz-kit | `8aa79ec1ca419718d70592f15d8cf39bb271e32f` | Imported implementation, root runtime/lock, substrate, SpruceGoose decisions/current state, and relevant test contracts |
| coop_substrate | `ef206957eb041f8b8f011a9721886e66048a09e2` | [Supplied upstream README][coop-upstream] |
| sprucegoose | `089db45cbe57abbde6c49a601eb3403897103020` | [Supplied upstream README][sg-upstream] |
| truck-shop | `b12fcb11d6d2a933350bf5423fb29b0ff20c4557` | Dependency declarations, fleet/work-order implementations, and tenancy design |
| spruce | `10b947988aa112dffda7c1d9b9eb67350bf9185d` | README, agent/runtime implementations, and persistence contract |

This is source/design review, not a fresh runtime benchmark or re-execution of
the imported application suites. Integration PR #1 reports the import's test
results; those results do not validate any adapter proposed here. The existing
ledger and identity tests were read as contract evidence ([coop-tests],
[identity-tests]). Proposed cross-system acceptance checks remain future work.

[integration-pr]: https://github.com/larsbx/biz-kit/pull/1
[substrate]: ../../apps/coop_substrate/SUBSTRATE.md
[coop-readme]: ../../apps/coop_substrate/README.md
[coop-mix]: ../../apps/coop_substrate/mix.exs
[coop-log]: ../../apps/coop_substrate/lib/coop_substrate/log.ex
[envelope]: ../../apps/coop_substrate/lib/coop_substrate/protocol/envelope.ex
[types]: ../../apps/coop_substrate/lib/coop_substrate/protocol/type_registry.ex
[validity]: ../../apps/coop_substrate/lib/coop_substrate/protocol/validity.ex
[coop-config]: ../../apps/coop_substrate/config/config.exs
[coop-prod]: ../../apps/coop_substrate/config/prod.exs
[coop-tests]: ../../apps/coop_substrate/test/log_test.exs
[dispatch-readme]: ../../apps/dispatch/README.md
[dispatch-outbox]: ../../apps/dispatch/lib/dispatch/outbox/publisher.ex
[dispatch-outbox-schema]: ../../apps/dispatch/priv/repo/migrations/20260918210000_add_transactional_outbox.exs
[oidc]: ../../apps/dispatch/lib/dispatch/identity/tokens/oidc.ex
[principal]: ../../apps/dispatch/lib/dispatch/identity/principal_resolution.ex
[dispatch-user]: ../../apps/dispatch/lib/dispatch/accounts/user.ex
[vehicle]: ../../apps/dispatch/lib/dispatch/fleet/vehicle.ex
[authority-planes]: ../../apps/spruce_goose/docs/authority-planes.md
[current-state]: ../../apps/spruce_goose/docs/current-state.md
[sg-decisions]: ../../apps/spruce_goose/docs/decisions/2026-09-08-kernel-and-ledger-shape.md
[notes]: ../../apps/spruce_goose/lib/spruce_goose/notes/note.ex
[ash-event]: ../../apps/spruce_goose/lib/spruce_goose/events/event.ex
[clear-notes]: ../../apps/spruce_goose/lib/spruce_goose/events/clear_records.ex
[certified]: ../../apps/spruce_goose/lib/spruce_goose/kernel/certified_event.ex
[canonical]: ../../apps/spruce_goose/lib/spruce_goose/kernel/canonical.ex
[pg-ledger]: ../../apps/spruce_goose/lib/spruce_goose/kernel/postgres/event_ledger.ex
[shadow]: ../../apps/spruce_goose/lib/spruce_goose/kernel/shadow_events.ex
[outbox-delivery]: ../../apps/spruce_goose/docs/outbox-delivery.md
[sg-outbox-schema]: ../../apps/spruce_goose/priv/repo/migrations/20260728131000_add_transactional_outbox.exs
[identity]: ../../apps/spruce_goose/lib/spruce_goose/identity.ex
[identity-local]: ../../apps/spruce_goose/lib/spruce_goose/identity/local.ex
[identifier-model]: ../../apps/spruce_goose/docs/identifier-model.md
[identity-tests]: ../../apps/spruce_goose/test/identity_local_test.exs
[authorization]: ../../apps/spruce_goose/docs/authorization.md
[sg-user]: ../../apps/spruce_goose/lib/spruce_goose/accounts/user.ex
[sg-token]: ../../apps/spruce_goose/lib/spruce_goose/accounts/token.ex
[sg-oauth]: ../../apps/spruce_goose/lib/spruce_goose/oauth2_server.ex
[actor-plug]: ../../apps/spruce_goose/lib/spruce_goose/web/actor_plug.ex
[keel-readme]: ../../apps/keel/README.md
[ownership]: ../../apps/keel/lib/keel/ownership.ex
[primitives]: ../../apps/keel/docs/PRIMITIVES.md
[runtime]: ../../config/runtime.exs
[root-mix]: ../../mix.exs
[lock]: ../../mix.lock
[coop-upstream]: https://github.com/larsbx/coop_substrate/blob/ef206957eb041f8b8f011a9721886e66048a09e2/README.md
[sg-upstream]: https://github.com/larsbx/sprucegoose/blob/089db45cbe57abbde6c49a601eb3403897103020/README.md
[truck-mix]: https://github.com/larsbx/truck-shop/blob/b12fcb11d6d2a933350bf5423fb29b0ff20c4557/mix.exs
[truck-tenancy]: https://github.com/larsbx/truck-shop/blob/b12fcb11d6d2a933350bf5423fb29b0ff20c4557/docs/architecture/multi_tenancy.md
[truck-model]: https://github.com/larsbx/truck-shop/blob/b12fcb11d6d2a933350bf5423fb29b0ff20c4557/lib/truck_shop/fleet/truck.ex
[work-order]: https://github.com/larsbx/truck-shop/blob/b12fcb11d6d2a933350bf5423fb29b0ff20c4557/lib/truck_shop/maintenance/work_order.ex
[spruce-readme]: https://github.com/larsbx/spruce/blob/10b947988aa112dffda7c1d9b9eb67350bf9185d/README.md
[spruce-agent]: https://github.com/larsbx/spruce/blob/10b947988aa112dffda7c1d9b9eb67350bf9185d/apps/spruce_core/lib/spruce/resources/agent.ex
[spruce-runtime]: https://github.com/larsbx/spruce/blob/10b947988aa112dffda7c1d9b9eb67350bf9185d/apps/spruce_runtime/lib/spruce/runtime_agent.ex
[spruce-persistence]: https://github.com/larsbx/spruce/blob/10b947988aa112dffda7c1d9b9eb67350bf9185d/apps/spruce_core/lib/spruce/persistence.ex
