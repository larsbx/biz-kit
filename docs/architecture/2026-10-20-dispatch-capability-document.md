# Dispatch: the signed capability document

Date: 2026-10-20. Status: **implemented** in `apps/dispatch`
(`Dispatch.Access.CapabilityDocument`, `Dispatch.Access.CapabilitySigner`,
`DispatchWeb.RoleCapabilityController`). The client is the d-patch Android
field application.

## Why

d-patch §23.2: "Android features are enabled from a signed server capability
document, not from `if role == DRIVER` checks." The field application needs to
know which surfaces to offer the role assignment it acts under, and to keep
knowing while offline. Dispatch's role assignments are still Ash rows; they
move onto the ledger with the rest of dispatch in step 4 of
[one source of truth](2026-10-11-single-source-of-truth.md). Until then the
document is derived from those rows.

## Decision

Use the platform's one signature scheme rather than a new one: **Ed25519
(`CoopSubstrate.Crypto`) over `CoopEventCanonicalV1` bytes
(`CoopSubstrate.Canonical`)**, with the ledger's `k-` key identifiers. Dispatch
depends on `coop_substrate` for code only (`runtime: false`); it neither starts
nor writes the ledger.

An earlier draft (d-patch PR #12) signed a JWS with ES256 and its own key
scheme. That would have been a third signing convention beside the ledger's
and JOSE's, and was dropped before merge.

```
GET /v1/me/role-assignments   bearer → {role_assignments: [{id, label}]}
GET /v1/role-capabilities     bearer, X-Role-Assignment-ID → {document, signature, key_id}
```

- `document` is base64url canonical CBOR of the claims; `signature` is
  base64url Ed25519 over exactly those bytes. The client verifies before it
  decodes, so nothing unverified is ever parsed for meaning.
- The claims carry `schema: "DispatchCapabilityDocumentV1"` and no `type`, so a
  document can never be read as a ledger envelope, command, enrolment
  statement or feed read, and none of those verifies as a document.
- Claims: `sub`, `tenant_id`, `participant_id`, `role_assignment_id`, `role`
  (`key`, `label`, `version`), `capabilities` with their constraints,
  `features`, `status_options`, `iat`, `exp` (twelve hours). A feature is
  published only when the assignment holds the capability it exercises: a
  role profile cannot grant.
- `GET /v1/me/role-assignments` runs before an assignment is selected, behind
  authentication alone, and returns identifiers and labels only.

## What it is not

A **service attestation**, not a person's signature and not authority. It says
what dispatch told this session it may be offered. Every request is authorized
again by the Ash policies behind it, so a stale or tampered copy can at worst
offer a control the server refuses. It is not a grant, does not replace the
ledger's grants, and is retired when dispatch's roles become ledger grants and
the client reads them from the [change feed](2026-10-18-change-feed.md).

## Keys

`DISPATCH_CAPABILITY_SIGNING_SEED`: a base64url 32-byte Ed25519 seed, loaded at
runtime. `apps/dispatch/config/{dev,test}.exs` carry a **published development
seed** so a clean checkout signs documents the debug Android build can pin;
`Dispatch.Config` fails production startup on that seed (compared by full
public key, not by `k-` identifier) or on none. Outside production a missing
seed answers `503 CAPABILITY_SIGNING_UNAVAILABLE`, never an unsigned document.
The Android release build pins the deployment's public key at build time.

## Contract

`apps/dispatch/contracts/openapi.json` is generated from the router
(`mix openapi.generate`) and checked in CI (`mix openapi.check`). The field
application's hand-written DTOs are held to a copy of it by its
`ContractConformanceTest`.

## Verification

- `Dispatch.Access.CapabilitySignerTest`: verification as the client does it;
  the served bytes are canonical; any altered part, another key, or bytes
  signed under another schema fail; the test seed is the development seed
  production refuses.
- `Dispatch.ConfigTest`: production refuses the development seed and a
  missing or unreadable one; a deployment's own seed passes.
- `DispatchWeb.RoleCapabilityControllerTest` (integration tier): every served
  document is verified before its claims are asserted; deny paths for no
  token, ambiguous selection, another principal's assignment, a revoked
  assignment, and an unusable seed.
- CI runs dispatch's unit tier and the contract check; the integration tier
  needs PostGIS and runs locally.
