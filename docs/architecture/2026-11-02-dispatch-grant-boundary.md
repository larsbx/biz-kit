# Dispatch current-grant boundary and Proof Bank obligations

Issue: [#254](https://github.com/larsbx/biz-kit/issues/254).
Related abstract correspondence pilot: [#253](https://github.com/larsbx/biz-kit/pull/253).

## Boundary

`Board.transition/4` retains its early capability/ownership checks as preflight.
After locking the trip, `MutationAuthority.transition/1` locks the **selected**
tenant-scoped role assignment with PostgreSQL `FOR SHARE`, reloads it, locks and
reloads its current role definition, and checks current capability, definition
status, validity interval, principal, organization, and organization scope.
Unsupported constraints on this Board capability fail closed. The selected
assignment is never replaced with another assignment held by the same principal.
Ordinary UPDATE/DELETE operations conflict with these locks; the locks last
through the trip update, audit append, and transaction commit/rollback.

Authenticated HTTP actors also retain non-bearer authentication metadata.
Current participant/user binding and activity are checked under shared row locks;
OIDC expiry is checked against a fresh server instant after lock waits. Identity
sessions are checked afresh through their non-bearer reference, including logout,
expiry, identity unbinding and the explicit mobile-principal mapping. Raw bearer
tokens are not added to Actor or the audit. Direct internal actors have no HTTP
session; their selected database grant still receives the same revalidation.

The successful audit uses the freshly resolved assignment and admission time.
A denied operation must leave the trip's status, version, end time and entire
existing audit history unchanged. No commercial capability or signed business
mutation path is added: this remains the carrier's nonbinding trip-status API.

## Executable correspondence obligations

These extend the pilot's D-ORG, D-STALE, D-TERMINAL and D-AUDIT links. They are
**runtime conformance obligations**, not new Lean theorems. The abstract model's
authorized-actor premise alone does not establish any row below.

| ID | Required runtime evidence | Witness |
| --- | --- | --- |
| D-AUTH-CURRENT | A selected grant revoked/deactivated/expired while the requester waits is refused | `BoardGrantConcurrencyTest`, committed-session denial cases |
| D-AUTH-DEFINITION | Supersession, retirement or removal of the current capability is observed | Definition-change denial cases |
| D-AUTH-SELECTED | A second live role cannot rescue the revoked selection; revoking an unselected role does not invalidate a live selected grant | Multiple-role denial/control cases; audit selected-ID assertion |
| D-AUTH-TIME | Captured `Actor.at` cannot freeze authority; token/session expiry during a wait refuses mutation | Expiry cases and fresh audit-time control |
| D-AUTH-IDENTITY | Current session reference, account binding, tenant, principal and organization must agree | HTTP-originated session endings and snapshot-context cases |
| D-AUTH-SERIALIZE | Ordinary grant/definition changes wait behind an admitted mutation until commit | Reverse-interleaving lock-graph assertions |
| D-AUTH-ATOMIC | Denial preserves all trip fields and pre-existing audit rows | Before/after database snapshots |

The regression uses `Sandbox.checkout(Repo, sandbox: false)` for independent
committed sessions. The holder only locks the trip. `pg_blocking_pids` verifies
the particular requester is waiting on that holder before the authority changer
runs on a third connection and finishes its commit. The observer is a fourth
connection. No shared Sandbox transaction or timing guess establishes revocation
ordering. The separate token-expiry case waits for the actual expiry instant;
Identity session expiry is deterministic through the test singleton's ETS state.

## Evidence and acceptance

See `docs/evidence/dispatch-grants/` for exact source/test revisions, command
results and source digests. The dedicated `Dispatch grant boundary acceptance`
workflow checks out the actual PR head SHA, asserts it, runs the focused suite
then the full PostgreSQL/PostGIS Dispatch suite and uploads SHA-named logs.
A passing log from another revision does not satisfy this obligation.

Model-to-runtime refinement remains **not established**, the Proof Bank packet
remains **unverified / needs_owner_review**, and activation remains **inert**.
Finite concurrency tests do not prove all scheduler or database interleavings.

## Explicit limits

This change covers `Board.transition/4`. Other Board mutations, direct Ash action
entry points, jobs and long-lived reads require their own boundary review; this
is not an application-wide fresh-authority claim. Identity's singleton is outside
the PostgreSQL transaction. Its live-session check is an admission check, not an
atomic cross-store serialization guarantee for a logout that races *after* that
check. Likewise time validity is decided at admission, not at the physical commit
instant. No runtime refinement proof is claimed.
