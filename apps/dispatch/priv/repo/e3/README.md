# E3 migration SQL and database acceptance

`up.sql` and `down.sql` are the source used by both the Ecto migration and the
standalone PostgreSQL runner. Each `-- e3:statement` line separates one top-level
statement. The migration executes those statements individually inside Ecto's
normal migration transaction. Do not replace the markers with semicolon splitting:
PL/pgSQL bodies contain internal semicolons.

The policy is about simultaneous committed `ACTIVE` rows for a global User. It
does not compare `starts_at` / `ends_at`. The retained E1 index is supplemented by
a global partial unique index for exclusive/exclusive pairs and an immediate
GiST exclusion constraint for mixed pairs. Concurrent/concurrent pairs remain
permitted. PostgreSQL 16 or later and visible `btree_gist` UUID equality / Boolean
inequality operator classes are checked explicitly. An older installed extension
is not silently upgraded.

The migration is a maintenance operation: it locks assignments, participants,
role assignments and role definitions before auditing/backfilling identities.
It refuses missing tenant-matching identities, active incompatible pairs, or any
legacy active concurrent assignment whose original selected role was never
persisted. It never guesses that provenance or changes assignment status/mode.
The transaction rolls back on refusal. A missing provenance value on an inactive
legacy concurrent row is preserved; the row cannot become active under the new
check constraint.

The composite participant foreign key preserves the tenant/participant/User
binding. Optional role/definition foreign keys preserve the referenced IDs.
Grant validity, tenant/principal match, profile capability, actor authorization
and allowed lifecycle transitions remain responsibilities of the trusted runtime
writer. A privileged raw INSERT is not attested by this database schema. The
update trigger prevents changing identity, load or the frozen policy/source tuple
on an already inserted assignment, including a planned or terminal assignment.
Writing the same values is allowed.

## Schema ownership

The three new Assignment UUID attributes belong in its Ash resource snapshot.
`assignments/20261106170000.json` records them; its optional generated hash is
omitted instead of retaining the prior schema's hash. `extensions.json` records
`btree_gist`, matching the Repo extension inventory and this migration.
The following are deliberately maintained by this SQL migration, not declared as
Ash identities/relationships and not added to its generated snapshots:

- `participants_tenant_id_id_user_id_key`, the composite FK target;
- assignment identity/source foreign keys and the active-concurrent source check;
- the two global E3 constraints/indexes;
- the immutable-policy trigger/function.

Participant's Ash resource definition is unchanged. Its triple unique key is not
a new tenant-scoped Ash identity. Assignment's historical E1 identity stays in the
resource and snapshots. Future generated migrations must preserve these SQL-owned
objects; do not infer that the global User index is tenant scoped.

## Disposable acceptance

From the repository root:

```sh
PGPASSWORD=postgres bash scripts/dispatch/check-e3-database.sh
```

The runner defaults to PostgreSQL at `127.0.0.1:5432`, administrative role
`postgres`. `DISPATCH_E3_PGHOST`, `DISPATCH_E3_PGPORT`, `DISPATCH_E3_PGUSER` and
`DISPATCH_E3_PGPASSWORD` can select the disposable test server. The role must be
able to create/drop databases and install `btree_gist`. `DATABASE_URL` is ignored.
The runner creates its own `dispatch_e3_acceptance_*` databases, records only
those it successfully created, and drops only those names on exit. It never
migrates the existing application database.

`fixture.sql` supplies only the relevant pre-migration schema, with matching key
types, required columns and the original E1 index. This is intentionally a database
policy fixture rather than a substitute for the complete Ash application tests.
`test_helpers.sql` contains test-only functions; it is never part of the migration.

Acceptance covers:

- atomic refusal of missing/wrong-tenant identity, cross-tenant X/X and X/C
  baselines, and an active concurrent row without original role provenance;
- successful identity backfill that preserves planned and terminal policy values;
- all four mode pairs, for the same participant, another same-tenant participant,
  and a cross-tenant participant sharing the User, through both INSERT and UPDATE;
- independent Users, planning without reservation, expired timestamps still
  occupying, and committed/rolled-back cancellation, completion and activation;
- NULL/spoofed identity, NULL mode, missing/nonexistent source IDs, immutable tuple
  fields, same-value updates, and restricted referenced participant/source deletion;
- eleven separate-connection Read Committed races: X/X, X/C and C/X with both
  first-transaction commit and rollback; C/C committing while the first transaction
  stays open; cancellation/completion with both commit and rollback;
- down/up preserving status/mode while keeping E1 and the shared extension.

The conflicting races observe the second backend waiting on a PostgreSQL lock
before committing or rolling back the first transaction. They have bounded waits
and fail if the expected SQLSTATE or committed row count differs. They demonstrate
the stated schedules on the tested PostgreSQL version; they are not a proof of all
possible implementation executions.
