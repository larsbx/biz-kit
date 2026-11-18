# T0 multi-organization source review: first evidence and exclusions

Date: 2026-11-01. Baseline reviewed: `main` at
`4c550f01effe1bedba235fa68899e1b435bdde02`; subsequent fixes are
proposed in PR #234. **This is a partial static review, not full platform
isolation certification.** T0 remains open in issue #233.

## Reproducible queue

`python3 tools/tenant_inventory.py --revision <exact commit> --summary`
and `python3 tools/tenant_inventory.py --revision <exact commit> --output
tenancy-inventory.json` enumerate production Elixir sources under
`apps/*/lib/**/*.ex`. The dedicated GitHub Actions lane also publishes this
JSON as a build artifact. The scanner distinguishes attribute-tenanted Ash
resources, unscoped Ash resources, plain Ecto schemas, and source-level
`Repo.*`/authorization-bypass candidates.

This is a **review queue**: string search is neither a complete Elixir parser
nor proof of policy enforcement, RLS, correct transitive joins, or absence of
alternate writers. Never infer that a module without a candidate is safe.
Classify its source ownership and trace the actual runtime call path.

## Inspected boundaries

| Surface | Source evidence | Status / required next proof |
| --- | --- | --- |
| Dispatch user and organization | `apps/dispatch/lib/dispatch/accounts/{user,organization}.ex` | Both are intentionally global Ash resources. A global directory entry is not a business authorization; restrict its projection and enrollment mutation paths. |
| Dispatch participant, assignment, role definition, membership, device, contact, fleet and operational entities | `apps/dispatch/lib/dispatch/accounts/{participant,role_assignment,role_definition,organization_membership,device,contact}.ex`; `apps/dispatch/lib/dispatch/fleet/{load,load_party,stop,stop_party,assignment}.ex` | Inspected resources declare Ash attribute-based `tenant_id` tenancy. This is useful application scoping, **not evidence of DB RLS or all-relationship safety**. Validate raw joins, bulk operations, cross-tenant foreign keys and every `authorize?: false` path. |
| Role resolution | `apps/dispatch/lib/dispatch/identity/principal_resolution.ex` | Global directory query exposes only identifiers; role lookup resolves inside the selected tenant. PR #234 adds organization lifecycle checks and revalidation of participant and global user status. Still test token/session unbinding, concurrency and stream effects at exact head. |
| Administrative mutation | `apps/dispatch/lib/dispatch/accounts/administration.ex` | At baseline, a preloaded actor was checked under the organization lock without refreshing actor/grant status. PR #234 locks actor role, participant, user, organization and role-definition rows after the organization advisory lock, then revalidates before grant/revoke. A two-connection PostgreSQL race test is included but **hosted results remain unverified**. Audit every independent revocation/offboarding path for the same serialization boundary. |
| Dispatch transport bookkeeping | `apps/dispatch/lib/dispatch/{idempotency/record,outbox/event}.ex` | Plain Ecto schemas with `tenant_id`, outside Ash's tenancy checks. `Idempotency` scopes claim/replay by tenant and role assignment; `purge_expired` is a global maintenance operation. `Outbox.Publisher` globally polls pending rows, publishes topic/payload and marks them published. Trace writers, topic names and SSE subscribers to verify tenant-namespaced notifications and no payload leakage. |
| Agent operational persistence | `apps/agent_ops_store/lib/agent_ops_store/postgres.ex` | Raw SQL uses effect IDs and carries tenant/chapter/project identifiers. Its module contract explicitly requires an already-authorized trusted host. Verify host admission, DB role privileges, effect ID uniqueness/replay and every read/claim path across tenants; an ID alone is not an authority grant. |
| Existing Eatsbot commercial model | `apps/eatsbot_core/lib/products/{product,variant,price}.ex`, `carts/cart.ex`, `orders/order.ex` | **Shared-tenant rollout blocker.** Inspected Ash resources do not declare `multitenancy` or a tenant/merchant owner attribute. Product's read policy broadly allows reads; Cart has an `always()` bypass policy. Order identity `[:channel,:idempotency_key]` is not merchant-scoped. These resources belong to Eatsbot's existing isolated product/runtime, not a safe multi-merchant shared writer. |
| Legacy SpruceGoose workflow model | `apps/spruce_goose/lib/spruce_goose/workflows/{project,task}.ex`; `actors/grant.ex` | **Shared-tenant rollout blocker until legacy writer retirement or explicit migration.** Inspected resources have no Ash tenancy block; grants use fleet/project scopes rather than home tenant boundaries. The one-ledger cutover remains incomplete; do not treat an unscoped legacy view as independently isolated shared tenancy. |
| Provider and transport | `apps/biz_kit_identity/lib/biz_kit/identity/resolver.ex`; federation draft docs | Provider issuer/subject binding is intentionally provider-neutral; do not substitute provider organizations for business authorization. Federation over Iroh/Halaqa remains an independently staged protocol and does not satisfy shared SQL tenancy. NetBird and WorkOS expansion remain deferred. |

## Next reproducible acceptance obligations

**T0 exit** requires an exact-head inventory of *all* production Ash and Ecto
resources, global read exceptions, direct SQL, API endpoints, agents, jobs,
extensions, evidence/object stores, cache/search and event/writer paths.
Sign off each candidate as global non-authoritative metadata, single-home
owned, explicit partner-scoped, legacy isolated or unresolved. Document the
enforced actor-to-home boundary and its negative tests.

**T1 exit** requires a server-derived single active context across HTTP,
native, stream, administrative and worker entrypoints. Revoke role, user,
participant and organization independently. Demonstrate that a held actor
cannot authorize a new effect. Test the organization-lock administrative
race with two distinct PostgreSQL connections; a passing sequential unit
test is not enough.

**T2 exit** requires PostgreSQL/PostGIS hosted integration and a reviewed
transaction-local tenant/RLS or equivalent enforced DB policy. Include
same-home positive controls and foreign-key/upsert/join/aggregate/cache/SSE
negative controls. For Eatsbot, first decide merchant ownership, scope all
public reads and writers, and migrate uniqueness/idempotency semantics.
For SpruceGoose, first prove one authoritative writer and preserve accepted
ledger history. No automatic production schema cutover is implied.

The partial source inspection above is a prioritization aid. It does not
establish a production exploit or a completed security guarantee.
