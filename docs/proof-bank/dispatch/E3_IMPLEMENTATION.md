# E3 driver assignment implementation

Status: owner-approved implementation for a **draft PR**, with migrations
executable only against disposable PostgreSQL test databases during this work.
Approval on 2026-11-06 followed an exact policy and schema proposal. This is not
approval to merge, deploy, or migrate a live operational database.

## Operational contract

The occupancy key is the canonical `Dispatch.Accounts.User.id`, across all
tenants sharing this Dispatch PostgreSQL database. For any two distinct ACTIVE
assignments belonging to the same User, coexistence is permitted exactly when
both assignments carry the explicitly concurrent profile snapshot:

| First mode | Second mode | Both ACTIVE for the same User |
| --- | --- | --- |
| Exclusive | Exclusive | Refused |
| Exclusive | Concurrent | Refused |
| Concurrent | Exclusive | Refused |
| Concurrent | Concurrent | Permitted |

Different Users do not conflict under this rule. The User key is an account
identity, not biometric proof that two accounts are different people. Other
Dispatch databases and external scheduling systems are outside the constraint.

E1 remains the historical rule: same tenant and participant, both exclusive.
E2 extends that local key to either-exclusive pairs. E3 uses the global User
key and the same either-exclusive test. With consistent participant-to-User
binding, E3 implies E2 and E1. The reverse implications do not hold.

“Overlapping” means simultaneously committed ACTIVE statuses, not overlapping
scheduled intervals. PLANNED assignments reserve no occupancy. A future start,
a past recorded end, or disjoint timestamps never release an ACTIVE assignment.
A committed COMPLETED or CANCELLED status does release it; rollback preserves
the prior occupancy. Closing a participant, suspending a User, revoking a role,
logging out, or allowing a grant to expire does not cancel active work. A carrier
may still complete or cancel that work through an authorized Board action.

This supports legitimate multi-organization work sequentially, or concurrently
when **all** active assignments are explicitly concurrent. A carrier's exclusive
trip blocks another carrier's trip for the same account. Its error response is
only `the driver is unavailable for this assignment`; it exposes no conflicting
carrier, tenant, load, assignment, or source role. Each operational request still
acts under exactly one locally authorized role. No cross-tenant capability union
or cross-tenant work listing is introduced.

## Immutable identity and profile provenance

`Assignment.plan` derives these private values on the server:

- `operator_user_id` from the tenant-matching operator participant;
- `operator_role_assignment_id` from the selected role argument, when supplied;
- `operator_role_definition_id` from that role's definition;
- `operator_exclusive` from the compiled allowlisted profile's callback.

The assignment's tenant, load, participant, User, role source, definition source,
mode and primary key cannot be updated after insertion. Changes require
cancelling the old assignment and planning a replacement. No action accepts a
caller-asserted User or concurrency Boolean. A caller that deliberately uses
privileged raw SQL to forge a new row's provenance is outside the trusted writer
boundary; the SQL constraints enforce compatibility of stored values, not the
semantics of an arbitrary executable profile.

An explicit role must belong to the operator participant in the same tenant and
load carrier organization. Participant and User must be ACTIVE. The grant must
be in force, its tenant-matching definition must be ACTIVE, and its allowlisted
profile must carry `assignment.read.self`. SELF and ORGANIZATION scopes are
confined by that principal/carrier binding. A LOAD scope must match the load and
have a current CARRIER load-party relationship. An ASSIGNMENT scope must match
the assignment. A STOP scope does not authorize operating the whole assignment.
An invalid explicit source is rejected, including an unrelated concurrent role.

Omitting the source preserves the exclusive default. On activation, such a
historical/default exclusive assignment still needs a current applicable
exclusive driving grant. A historical concurrent row without provenance cannot
activate. Supplying a source freezes its exact role and definition IDs; activation
revalidates that source and its current Boolean against the snapshot. A revoked,
expired, superseded, rebound or differently configured source cannot silently be
replaced by another grant. Relabeling a definition without changing its active
policy does not invalidate the snapshot solely because its version changed.

Board first filters driving grants to those applicable to the requested load,
then deterministically prefers an exclusive grant if several remain. An unrelated
exclusive scoped role cannot hide a valid concurrent source. Database row order
does not choose a relaxed mode. The selected source is revalidated under locks.
The test Courier is still a test/development profile, not a new production profile.

## Database implementation

The migration is
`apps/dispatch/priv/repo/migrations/20261106170000_global_operator_compatibility.exs`.
Its SQL is also used by the disposable database acceptance harness, avoiding a
second hand-written imitation of the migration.

The two complementary occupancy constraints are:

```sql
CREATE UNIQUE INDEX assignments_active_exclusive_user_uniq
  ON assignments (operator_user_id)
  WHERE status = 'ACTIVE' AND operator_exclusive;

ALTER TABLE assignments
  ADD CONSTRAINT assignments_active_mixed_user_modes_excl
  EXCLUDE USING gist (
    operator_user_id WITH =,
    operator_exclusive WITH <>
  )
  WHERE (status = 'ACTIVE')
  NOT DEFERRABLE;
```

The unique index rejects exclusive/exclusive pairs. The exclusion rejects both
mixed-mode orders. Neither rejects concurrent/concurrent. The old E1 index is
retained during rollout. A single partial unique index on exclusive rows is
insufficient for mixed pairs; a universal unique index on active Users would
wrongly prohibit approved concurrent operation.

`operator_user_id` is NOT NULL. A participant unique key over
`(tenant_id, id, user_id)` supports an assignment foreign key over
`(tenant_id, operator_participant_id, operator_user_id)` with restrictive update
and delete behavior. This prevents a spoofed User binding or a referenced
participant remap. The immutable-snapshot trigger refuses predicate and identity
rewrites. An ACTIVE concurrent row requires both source IDs. These are database
checks, including for direct SQL writes that retain the constraints and triggers.

The GiST implementation requires `btree_gist` with UUID equality and Boolean
inequality support. PostgreSQL 16 is the repository baseline. Extension
installation does not upgrade an older installed extension: the migration must
refuse missing operator capability rather than assuming `CREATE EXTENSION IF NOT
EXISTS` supplies it. Deployments must review the installed extension version and
any upgrade separately.

Preflight runs before enforcement becomes active. Orphaned or inconsistent
participant bindings, existing global exclusive/exclusive or mixed active pairs,
and active concurrent assignments without trustworthy source provenance must
stop the migration. It never picks a winning carrier, silently cancels work,
changes a snapshot mode, or fabricates a role source from current grants. Existing
inactive source-less concurrent history can remain history, but cannot activate.
A live rollout therefore needs a separate inventory/remediation decision and a
maintenance/locking plan. No such live remediation is performed by this PR.
The NOT NULL binding intentionally makes old assignment writers incompatible:
this is a coordinated migration/release with assignment writes paused, not an
unattended rolling deployment. Reverting the migration also removes E3 and is
not an approved production recovery action merely because `down` exists.

## Transactions, errors and supported writers

Board is the supported operational writer for HTTP/portal assignment planning
and lifecycle transitions. Its existing transaction includes the mutation and
one audit append. It locks the trip and share-locks its load before re-reading selected actor
authority, ownership, version and source state. Planning also locks and rechecks
load ownership inside its transaction. It validates the stored operator policy
as well. Completion/cancellation close location consents in that transaction.
A rejected update or rollback does not commit a lifecycle version/audit event.
The post-commit response reload remains a separate read, not part of atomicity.

`OperatorPolicy` runs inside the mutation transaction. It share-locks the load,
participant, User, selected role and role definition before using their current
values. Where LOAD scope applies it also locks the relevant party relationship.
Following participant and role references uses separate locked reads so that an
already-waiting query cannot validate a newly referenced User or definition
without locking it. Clock time is taken after source locks. Direct Ash lifecycle
actions additionally lock/re-read the assignment and enforce source-state and
version guards before activation/completion/cancellation.

Compatible share locks do **not** serialize two different assignments. The
PostgreSQL unique and exclusion constraints arbitrate occupancy on distinct
rows, including cross-tenant writers. No application `count` query, distributed
mutex, or global User `FOR UPDATE` lock is used for E3. Read Committed is the
acceptance baseline. Arbitrary multi-row batch transactions can still deadlock
or fail under contention; callers must handle database aborts. No general
liveness, fairness, deadlock-freedom or automatic retry theorem is claimed.

The named uniqueness and exclusion constraints are mapped through the pinned
AshPostgres API to the same generic Board conflict. Direct SQL receives its
normal SQLSTATE (`23505` or `23P01`); privileged diagnostics are not a public API.

Direct Ash actions have resource-level identity/policy/lifecycle validation, and
raw SQL encounters database occupancy and immutability checks. Neither is an
approved substitute for Board's actor authorization and audit contract. New
imports, jobs, bulk writers or administrative repair paths must explicitly use
Board or implement and test an equivalent reviewed boundary. Privileged ability
to drop constraints, disable triggers, or forge stored source provenance is not
part of the claimed protection.

Locks order database mutations to identity and authority relative to admission.
They do not freeze the clock. A grant can expire while an activation waits on an
occupancy constraint after policy admission. Session validity and every grant's
expiry at the physical commit instant remain a separate requirement; this PR
does not claim to solve or prove them.

## Acceptance and formal correspondence

The workflow `Proof Bank — Dispatch model/runtime correspondence` records and
checks the exact PR head SHA in every job. It replaces PR #312's two expected-red
runtime probes and temporary profile patch experiment with positive E3 policy
acceptance. The old documents/receipts remain historical evidence of E1 and the
two limitations at their pinned commits.

The PostgreSQL gates use independently checked-out, committed connections, not
several tasks sharing one sandbox transaction. Interleaving tests observe actual
blocking with `pg_blocking_pids` before releasing a held transaction. Required
cases include mixed modes in both orders, shared Users across tenants and
re-enrolment, valid concurrent coexistence, distinct Users, a third exclusive
assignment after two concurrent ones, committed and rolled-back terminal
release, identity/mode mutation rejection, source-role/definition revalidation,
direct Ash and SQL writers, and audit/version outcomes. Migration acceptance
also exercises conflicting baselines and required extension support in newly
created disposable databases.

The Lean extension connects the Boolean SQL decomposition to the E3 conflict
relation, records the participant/User consistency premise for E3 implying E2,
and models fresh assignment insertion with immutable snapshots. The Quint
extension adds enough trips and Users to distinguish C+C+X from unrelated-user
work and checks staged terminal commit/rollback and refused snapshot mutation.
Deliberately broken model controls must produce an invariant violation, not a
parse error or an execution failure.

These are complementary evidence. Lean proves the stated abstract propositions
under its explicit premises. Quint explores a finite abstraction. PostgreSQL
acceptance exercises the real constraint and writer paths. Passing all three is
**not a proof that the complete Elixir/Ash/PostgreSQL implementation refines the
model**. Current CI results and their exact revision must accompany review; old
61-test/14-case receipts cannot be reused as evidence for this changed runtime.

## Release boundary

This PR may be prepared and validated as a draft. Merge, production migration,
production extension upgrades, remediation of real conflicts and deployment
require the owner's separate decision. Until that happens, deployed behavior
must not be described as E3 merely because this branch or its acceptance tests
exist.
