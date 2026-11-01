# Multi-organization tenancy: home isolation before provider or mesh expansion

Date: 2026-11-01. Status: **adopted direction; staged implementation**.
Scope: Biz-kit shared installations, independently governed installations, and
the platform capabilities used by Dispatch, SchoolOps, commerce, sales and
extensions.

## Decision and priorities

**P0/P1: verify tenant isolation and explicit organizational authority before
expanding authentication products or private-network integrations.** WorkOS
feature expansion is tabled; NetBird integration is out of scope. Keep the
existing WorkOS provider adapter operational for compatibility, but do not use
WorkOS organization IDs or WorkOS roles as the source of Biz-kit business
authority. Do not add dependencies on WorkOS or NetBird for tenant correctness.
The existing [identity contract](2026-10-18-identity.md) remains authoritative:
authentication provider -> BizKit principal -> scoped ledger grant -> domain
admission. This decision does not remove existing sign-in paths.

Two deployment modes must work:

1. **Shared installation:** several independently administered organizations
   use one Biz-kit runtime, with isolation in every storage, authorization and
   asynchronous execution boundary. One governed home is the sole writer of its
   business facts; a common process/database does not imply a common authority.
2. **Independent home:** an organization operates its own instance, principal
   authority, data, grant history and writers. Inter-home communication is an
   explicit signed proposal/evidence/receipt exchange, not a shared database
   transaction or replication-based grant. The proposed Halaqa/Iroh federation
   remains a separate F1-F4 acceptance track; transport authenticity never
   grants domain write authority.

**Terminology must be explicit.** An `organization` is a legal/operational
business actor; a `tenant/home` is the governing data and command boundary;
a `principal` is a stable local identity; a `membership` expresses affiliation;
a `role assignment` expresses one bounded authority. These concepts are not
interchangeable. In Dispatch, the carrier's organization ID currently anchors
the tenant for a carrier-owned home, but a partner organization can appear in
scoped relationships within that same tenant. **Do not assert that every
`organization_id` equals `tenant_id`.** A person may have separate
participant identities and assignments in several tenants.

## Request and command authority contract

Every business read, command, stream, worker job and extension effect must
derive an immutable acting context from **server-side verified facts**:

- authenticated platform principal and current binding/session status;
- selected tenant/home and acting organization, resolved from one active
  assignment or an explicitly audited delegation;
- one current role/grant with scope, time, revocation state and relevant
  organizational lifecycle;
- target resource's owning home and (where different) its participating party;
- domain-specific relationship/consent/preconditions, and exact command
  admission revision.

A client-supplied tenant, organization, role ID, workspace ID, URL path, header
or extension manifest is a **selector**, never a grant. Do not implicitly
choose when several active contexts remain; do not union the grants of two
memberships, two roles or two homes. A membership is not permission. An
organization's kind, shared contact, searchable catalog entry or transport
peer is not permission.

A target owned by another home must be refused with no existence-bearing
metadata unless an explicitly named sharing relationship and the target
owner's domain authorization both permit the operation. Partner access to a
load/stop continues to require the active party record *and* the assignment.
Read visibility is not write authority: only the home/domain owner can commit
its business fact. All business writes remain behind signed command admission
and serialized version/precondition rechecks; an HTTP or plugin-specific
database writer is not an alternative authority.

## Persistence boundaries and threat model

- Audit every Ash resource for the `tenant_id` strategy and its read/create/
  update/upsert/bulk/destroy paths; enumerate global lookup resources as
  reviewed exceptions with restricted projections. Cross-tenant foreign keys,
  nested reads, preloads, through-relations and unique/upsert conflict targets
  must not defeat the scope.
- Parameterize tenant context from the verified actor, not request parameters.
  Audit all raw `Ecto.Repo` calls, SQL joins, migrations, projections and
  materialized views. Existing `authorize?: false` call sites remain explicit
  review points; that flag is not tenant isolation.
- Plan PostgreSQL RLS as defense in depth **after** enumerating owners,
  service roles, pools, transaction-local tenant settings, read models, backup
  and recovery, and migration/repair operations. A single broadly privileged
  shared DB connection cannot be called independently isolated just because
  Ash predicates exist. Do not enable blanket RLS without the transaction and
  operational compatibility gates.
- Signed ledger streams, sequence/cursor namespaces, canonical replay and
  idempotency keys require an explicit home owner. A shared append mechanism
  must not make another home's events readable or mutable by default.
- Object storage, evidence, artifacts, cache keys, search indexes, SSE,
  GraphQL, background jobs, agent tools, extension ports, logging and
  export/import must propagate the same context. An asynchronous handler must
  revalidate or bind an exact authorization revision before effect, never
  inherit unlimited authority from a previously active request.
- Audit records must contain actor principal, acting organization, home,
  selected assignment/grant, target owner, decision and immutable effect ID
  without leaking another tenant's payload.

## Independent conformance matrix (mandatory before production claims)

| Scenario | Required observation |
| --- | --- |
| A user belongs to homes A and B | No implicit authority union; explicit selection with organization-qualified labels |
| Same role name in A and B | Distinct selectable contexts; selecting B cannot read/write A |
| Forged tenant or role ID | Uniform refusal with no existence disclosure |
| Other tenant's primary key, upsert key or join row | No overwrite, conflict-based enumeration, leaked association or returned row |
| Search, pagination, aggregates, exports, SSE and cache | Exact tenant scoping, including reconnect and invalidation |
| Cross-org load/stop | Active matching party relationship and role required; cessation revokes access |
| Membership, role, organization or session revoked mid-flight | Recheck at effect/stream boundaries; no stale-actor commit |
| Two administrators mutate grants concurrently | Lock and transaction-time authority recheck; no last-admin bypass |
| Jobs, agents and extension adapters | Scope is explicit; missing/stale context refuses all effects |
| Separate deployed homes | No cross-home database or event writer; signed foreign evidence requires local admission |
| Organization migration/export | Exact owner/canonical records, keys, grants and audit references preserved; source writer fenced |

Include negative controls proving that same-home authorized work still succeeds,
rather than achieving isolation by denying all requests. Run database-backed
Dispatch/PostGIS tests in hosted CI on the exact PR revision, in addition to
pure and browser tests. Report independent results separately from fixtures,
architecture review, or a unit-only green job.

## Implementation stages

**T0 — inventory and threat model.** Enumerate organization/home ownership
across Ash resources, SQL, contracts, events, sessions, jobs and extension
adapters. Classify each record as global directory metadata, home-owned,
partner-visible or strictly private. Record all unsafe `authorize?: false`
and direct SQL paths and define refusal behavior before adding migrations.

**T1 — explicit acting context.** Keep `BizKit.Identity` provider-neutral and
`Dispatch.Identity.PrincipalResolution` as the current verified selector.
Make organization labels unambiguous and stop selecting or revalidating roles
of suspended/closed organizations. Next: standardize a home/organization
context value consumed by HTTP, live streams, jobs and extensions, with a
single revocation/freshness contract. Do not promote a plain client-supplied
context struct into verified authority.

**T2 — persistence isolation.** Reconcile shared schemas and home writers;
tighten Ash and raw SQL scopes; test unique indexes, upserts and cross-tenant
joins; implement reviewed PostgreSQL RLS and operational roles where feasible.
Close the required Dispatch/PostGIS hosted acceptance gate. Only then
describe a shared installation as independently isolated.

**T3 — partner collaboration.** Implement typed, explicit organization-to-
organization sharing/delegation per owned resource, with expiry, revocation,
audit receipts and the target owner's final domain admission; no implicit
capability union or direct cross-tenant row writes.

**T4 — portability.** Specify a signed organization export/import manifest,
identity/key references, ownership/history provenance, immutable record IDs,
replay verification and fencing/single-writer cutover. Verify shared-to-
independent-home migration and that former shared access ends.

WorkOS expansion, NetBird connectivity and native federation activation are
**deferred work**, not prerequisites for T0-T2. Existing providers and current
federation experiments remain untouched, and no production conversion or
global security guarantee is claimed by the first slice.

## First executable slice in this change

`Dispatch.Identity.PrincipalResolution.selectable/2` now returns
organization-qualified labels while preserving the existing `%{id, label}`
API shape. Authority is still chosen by assignment ID, never label. The
database-backed resolution checks current organization status before
selecting or revalidating an assignment; suspended/closed organizations cannot
remain active solely because a role row is still active. Integration tests
cover identical roles across organizations, selection under suspension and
stale-actor revalidation. This is **not** evidence of completed T2/RLS,
transaction-time grant checks, production federation or data migration.
