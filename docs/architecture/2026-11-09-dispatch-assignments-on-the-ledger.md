# Dispatch assignments on the ledger

Date: 2026-11-09. Status: **first slice implemented; Dispatch does not use it
yet.** This is the first Dispatch surface of
[consolidation step 4](2026-10-11-single-source-of-truth.md#concrete-implementation-order),
started by owner decision to close enforcement gap 7 one writer at a time
([roadmap](../roadmap.md)). It follows the shape of the
[first ledger task command](2026-10-11-first-ledger-task-command.md): define the
events and their authorization, extend the append gate, fold, and rebuild the
view from the ledger alone.

## What is on the ledger

`DispatchCore.Admission` (pure, in `apps/dispatch_core`) is registered with the
substrate like `RestaurantCore.Admission`. The single appender runs its check
on every event and folds admitted ones into the gate's `dispatch` state.

| Event | Signed by | Admitted when |
| --- | --- | --- |
| `DispatchDispatcherGrantedV1` | a declared governance key | the dispatcher key is not already granted for the tenant |
| `DispatchAssignmentPlannedV1` | a dispatcher granted for the tenant, with its key | the assignment id is new; it holds an operator, and optionally a vehicle and a trailer |
| `DispatchAssignmentTransitionV1` | the same | the expected version matches and the move is legal: `activate` (PLANNED → ACTIVE), `complete` (ACTIVE → COMPLETED), `cancel` (PLANNED or ACTIVE → CANCELLED) |

At `activate` the rule of `Dispatch.Fleet.Assignment`'s partial unique indexes
holds: an operator, a vehicle and a trailer are each on at most one ACTIVE
assignment per tenant. Completing or cancelling an ACTIVE assignment frees what
it held. Eight concurrent activations sharing a vehicle admit exactly one
(`CoopSubstrate.DispatchAssignmentsTest`); a restarted Log rebuilds the same
state from the ledger.

## Differences from Dispatch today

- **Every operator is exclusive.** Dispatch derives `operator_exclusive` from
  the operator's role profile. Profiles are not on the ledger, so the ledger
  takes the restrictive default; a profile that permits concurrency waits for
  role grants on the ledger (step 4's grants).
- **Dispatchers are keys, not sessions.** Dispatch authorizes a signed-in
  person by role. Here a governance grant binds a dispatcher key to a tenant,
  as restaurant devices are bound to a merchant.
- **Timing, loads and contacts are not modelled.** `starts_at`/`ends_at`,
  the load's own lifecycle, assignment contacts and location consents stay in
  Dispatch.

## Next, in order

1. **Dual-read parity.** Record the board's assignment transitions as these
   events alongside its row writes, and compare the fold with the rows.
   Differences must be explained before any switch.
2. **Command switch.** The board submits the signed event first and writes the
   row as a projection of the admitted event; a refused append changes no row.
3. **Fence.** Fence the old assignment writer so a covered command cannot
   succeed through the old path. `CoopSubstrate.WriterFence` fences a whole
   database, and Dispatch keeps its other tables, so this needs a
   table-scoped variant or the row writer's removal. Configuration rollback
   is not a fence.
