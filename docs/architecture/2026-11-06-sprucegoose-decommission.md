# SpruceGoose decommission checklist

Date: 2026-11-06. Status: **proposed checklist; nothing here is implemented
by this document.** It collects the removal conditions that existing decisions
already set, so that "SpruceGoose is decommissioned" has one testable meaning.
Sources: [one source of truth](2026-10-11-single-source-of-truth.md),
[what the ledger keeps from SpruceGoose](2026-10-20-sprucegoose-salvage.md),
[legacy grant history](2026-10-21-legacy-grant-history.md),
[first ledger task command](2026-10-11-first-ledger-task-command.md),
[native sign-in](2026-10-21-native-sign-in.md),
[project ownership](2026-11-02-project-ownership.md),
[consolidation](2026-10-30-postgres-event-log-redis-consolidation.md) and
[deploy](../deploy.md), read at main `a085ae0f`.

## Definition

SpruceGoose is decommissioned when all four hold:

1. **Surfaces.** Every live surface it serves is rehosted (§1).
2. **Authority.** Its three writers are fenced and a replay proof passes (§2).
3. **History.** Its retained history is preserved as inert audit data that
   grants no authority (§3).
4. **Mama.** The standalone production deployed from the `sprucegoose`
   repository (`ops/mama-authority`) meets its own succession and
   verified-retirement record. That record lives in the `sprucegoose`
   repository and is not restated here.

Only then are `apps/spruce_goose`, its release wiring and its settings removed.

## 1. Surfaces to rehost

| Surface | Depends on it | Requirement | Gate |
| --- | --- | --- | --- |
| `/auth`: WorkOS sign-in, native sign-in exchange, `BIZKIT_IDENTITY_BINDINGS` | d-patch; Dispatch's `BizKitSession` verifier | One authentication entry point outside SpruceGoose | d-patch native sign-in and Dispatch portal acceptance pass against the new host |
| `identity_native_sessions` and `SpruceGoose.Web.NativeSessionStore` | Every signed-in native device | Move the store and its rows, or end every session and require sign-in again (**owner decision**). Revocation stays atomic | Atomic native-session revocation tests pass on the new store |
| OAuth2 issuer for MCP clients (`SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS`, `OAUTH2_SIGNING_SECRET`) | MCP clients | Preserve client authorization and actor bindings; never merge principals on name or email | Each bound client authenticates with its existing binding |
| Task web view and API: commands, SSE feed, tasks, run readiness, project ownership, devices, enrolment, grants, offboarding, administrators, artifacts, blueprints | Operators | Already thin over `CoopSubstrate`; rehost on a ledger-only host | The browser workflow and HTTP suites pass against the new host |
| `/mcp` (AshAi over Ash resources) | Agents | Rebuild on task commands, or drop (**owner decision**) | Decided and recorded |
| `orchestration` release and `SpruceGoose.ReleaseTasks.migrate/0` | Deployment | The new host also creates and initializes the **ledger's** event store | `scripts/release-smoke.sh` equivalent passes without SpruceGoose |
| `ARTIFACT_STORE_ROOT` (`/var/lib/sprucegoose/artifacts`) | Ledger `ArtifactCustody` receipts | Receipts reference bytes outside the log; they stay readable | Every custody receipt's bytes re-hash to their recorded digest at the new location |
| CLI commands that sign ledger events | Operators | Keep them as `mix` tasks; legacy-writer commands go with the writer | Each retained command has a `mix` task and test |

## 2. Authority cutover

Writers to fence: the live task-row writer, the `certified_events` /
`ShadowEvents` writer, and the legacy `Actors` registry.

| Condition | State at `a085ae0f` | Gate |
| --- | --- | --- |
| Ledger coverage of retained paths | Lifecycle, todos, predecessor cycles, SOP versions, readiness, hierarchy and blueprints are on the ledger. Approvals still run legacy checks (`Revise`, `Blueprints.Applier`, `Checks.HasRole`) | Each retained approval path admitted by a signed ledger event, with a refusal test |
| Legacy task import | `SpruceGoose.Ledger` import receipts and baselines | Baseline events never overwrite existing ledger tasks |
| Project owners | Existing projects are ownerless and accept no new tasks until governance backfills them (principal kind, operator grant, owner) | Every live project has an owner |
| Dual-read parity | `ledger replay-status` | Only explained differences, such as the uncertified state moves of migration `20261021090000` |
| Signed fence | Not started | A covered command cannot succeed through a row write or the old writer, and a failed append changes no state. Configuration rollback is not a fence |
| Replay proof | Not started | Replay after the fence reproduces the projections |

## 3. History to preserve as inert audit data

None of it converts into ledger authorization.

- **Legacy grant registry,** including closed grants and `grant history`.
  Grants deleted before #50 cannot be reconstructed.
- **`certified_events`:** the original ETF bytes and their content identities.
- **`notes` and the old `events` table:** inventory, keep what is needed, and
  record digests and where the copies are kept. Never apply a generated Ash
  migration that drops them.
- **Ledger import receipts, grandfathered baselines, and the constitution and
  provenance bytes** that records reference (`priv/constitution/adopted.json`,
  the Systemwide SOP digest).
- **`outbox_events`:** drain or reconcile the backlog before the dispatcher and
  Oban are removed.

## 4. Not migrated

They are retired with the writer, per the salvage decision: wait notes; the
blocked, impact and critical-path views; inbox captures; boards, columns and
filters; runtime shadows; derivation permits and outcome receipts; release
provenance; the deployment domain; `Kernel.Constitution` (callers only in its
own test); Oban.

## Open

- **First governance seat held by a person.** The salvage decision deferred
  it to Keel. Project ownership now records principal kinds
  (`TaskPrincipalKindDeclaredV1`, declared `human` for owners), but this
  document does not establish that the rule is enforced for governance seats.
- **Spruce_goose CI.** Its test step in Consolidation and Project ownership
  acceptance are red on main, and stay out of scope until this checklist's
  rehosting begins.
