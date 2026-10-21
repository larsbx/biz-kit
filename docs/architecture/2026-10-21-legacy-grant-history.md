# Legacy grant history during SpruceGoose retirement

Date: 2026-10-21. Resolves primitive-audit D7 for future legacy revocations.

## Authority boundary

Keep the legacy registry operational until its writer is retired. PR #50
removed retired executor roles and other functionality; #51 removes boards,
columns, saved filters and inbox captures. Neither removes the remaining
legacy writer's authority consumers:

| Path | Authority read |
| --- | --- |
| CLI actor/grant creation, disable/enable and revoke | `Actors.Registry`: current global admin re-read inside the serialized registry transaction |
| Legacy workflow writes and scoped reads | `Checks.HasRole`, `Checks.Readable` and `Actors.Scope`: active grants for the named actor |
| Revision and blueprint approval, legacy recovery imports | `Revise`, `Blueprints.Applier`, `Ledger`: legacy role/scope checks |
| Legacy grant inventory and caller explanation | `Registry.grants`, `Scope.summary`, `whoami`: current active grants |
| Legacy historical audit | New admin-only `grant history [--actor NAME] [--role ROLE]`: active and closed grants, including IDs, grantor/time and revoker/time |
| Web grant creation, revocation, offboarding and task commands | `CoopSubstrate` signed ledger grants; `Web.GrantController` delegates to `CoopSubstrate.Devices`, never to `Actors.Grant` |

The ledger remains the destination for new consolidated authority. Its grant
IDs name signed events, and revocation retains historical grants with
`active: false`. A legacy actor name (`--as`) is a declaration, not a
credential or ledger principal. No migration invents principal bindings,
signatures or ledger authority from legacy rows, and neither registry grants
authority in the other. Legacy grant writes still bypass the legacy task
shadow-event wrapper, as before; the retained rows are not newly certified
ledger events. Timestamps describe the legacy interval; they do not prove
that a particular historical action was authorized.

## Change

`Grant.read` and the actor's grant relationship return active rows only;
`Grant.history` is the explicit unfiltered audit read. The CLI gates history
by global admin, as it does the existing registry inventory. All legacy
authorization consumers continue using the primary active read, including
the last-active-admin check. Removing the Ash destroy action makes revocation
an update naming `revoked_by`; the existing registry lock protects the current
admin check and closure together. A new grant receives a new ID and original
provenance is retained. The partial unique index allows only one active
`(actor_id, role, scope)` while allowing closed predecessors.

The database requires both revocation fields together and a revocation time
at or after the grant time. A trigger refuses deletion, changes to the
original authority/provenance, and any second change to a closed row. This
also makes a pre-upgrade binary's destructive revoke fail closed. Database
owners can still bypass triggers or truncate data; these are application and
ordinary SQL write protections, not an owner-proof audit store.

## Upgrade and rollback

1. Back up the database and stop legacy CLI/service writers. Do not resume
   old binaries against the migrated schema: their revoke operation will fail.
2. Run the normal release migration before starting the new release. Migration
   `20261021090000` adds nullable fields without backfilling dates, replaces
   the unique index in the same DDL transaction, and installs the checks and
   guard. Existing grants remain active under their original IDs and times.
   Ordinary index creation locks writes; schedule a maintenance window.
3. Confirm active inventories and `grant history`; run migration again to
   confirm it is a no-op. Start only the new writer.
4. A schema rollback is allowed only before any row has been closed. Once a
   revocation exists, downgrade raises before removing guards, columns or
   indexes. Keep history and roll forward; do not delete closed grants to
   make an old release start.

Grants deleted before this upgrade, including the retired executor-role rows
removed by #50, cannot be reconstructed. This change does not claim to
recover them. The historical rehearsal scripts under `ops/mama-authority`
remain evidence of their fixed old-schema rehearsals, not upgrade commands
for this schema. Final writer retirement must retain this registry history
as inert audit data; it must not convert it into ledger authorization.

## Constitutional roots

This governed change re-pins only `agent_charter` (exact registry source)
and `schema` (sorted migration paths and their byte digests) in
`priv/kernel/shadow-event-roots.json`. No past certified event is modified
or re-rooted. `grant_epoch` is unchanged because `Actors.Scope` is unchanged.
PR #51 landed first and changed the migration set and that scope source. This
policy retains its `grant_epoch` and recomputes `schema` from the combined
migration set; the root-policy test checks the resulting artifacts together.

## Validation contract

`grant_history_test.exs` covers provenance retention, authorization and
relationship filtering, revocation twice, regranting with a fresh identity,
duplicate-active refusal, revoked-admin refusal, last-admin protection,
history access and database mutation guards. `migration_upgrade_test.exs`
upgrades a pre-existing grant through the real migration chain, checks
idempotence, exercises a safe pre-adoption rollback and verifies that a
post-revocation rollback fails transactionally without losing history.
The existing separate-session registry tests check authorization after a
concurrent revocation. The root-policy test checks the exact adopted digests.
