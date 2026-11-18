# Dispatch board writes: current-grant revalidation (issue #254)

Date: 2026-11-02. Status: **implemented and regression-tested; not a
refinement proof.** Source of the finding: the Proof Bank Dispatch pilot
(#253) and [issue #254](https://github.com/larsbx/biz-kit/issues/254).

## Finding

`BizKitDispatch.lean` assumes an authorized actor. The runtime boundary did not
re-establish that assumption when it mutated. `Dispatch.Operations.Board` checked
`Actor.can?/2` before its transaction, against the role assignment and the
instant cached in the `Actor` struct. The transaction re-read trip ownership,
version and status after `lock_trip!/2`, but not the grant.

## Reproduction (revision `f284ac00`, tests only, `lib/` = main `27682a2f`)

`apps/dispatch/test/dispatch/operations/board_authority_concurrency_test.exs`
uses independently committed PostgreSQL sessions
(`Dispatch.Support.ConcurrentSessions`). A holder locks the trip row; the
transition passes its entry check and queues on that lock (asserted with
`pg_blocking_pids`); a third session commits a change; the assertion that the
transition is still queued holds; then the lock is released.

`mix test … --include integration --seed 0` → **11 tests, 9 failures.** Each
failure is an unauthorized success: `Board.transition/4` returned `{:ok, _}` and
the trip moved.

| Case | At `f284ac00` (main `lib/`) | At `7539063d` (fix) |
| --- | --- | --- |
| Selected assignment revoked during the lock wait | `{:ok, _}`, trip moved | `{:error, :forbidden}`, unchanged |
| Capability removed from the role definition during the wait | `{:ok, _}` | `:forbidden` |
| Assignment `ends_at` passes during the wait | `{:ok, _}` | `:forbidden` |
| Participant suspended during the wait | `{:ok, _}` | `:forbidden` |
| User suspended during the wait | `{:ok, _}` | `:forbidden` |
| Selected assignment revoked; a second one with the same capability still held | `{:ok, _}` | `:forbidden` (no union) |
| Assignment revoked before the call (stale snapshot) | `{:ok, _}` | `:forbidden` |
| Caller-chosen `at` inside an interval that has already ended | `{:ok, _}` | `:forbidden` |
| Every board write (`create_load`, `update_load`, `add_stop`, `plan`) with a stale snapshot | at least one `{:ok, _}` | all `:forbidden`, nothing written |
| Control: an unselected assignment revoked during the wait | `{:ok, _}` | `{:ok, _}` |
| Control: no change during the wait | `{:ok, _}` | `{:ok, _}` |

Each denied case asserts that the trip's status and version are unchanged and
that the tenant has zero audit events. Each control asserts version + 1 and
exactly one audit event naming the selected assignment.

This is a demonstrated stale-authority write in a test database. It is not
evidence of exploitation in any deployment.

## Correction (revision `7539063d`)

`Dispatch.Identity.PrincipalResolution.authorize/3`:

1. With `lock: true`, takes `FOR SHARE` locks on the role assignment and its
   definition, and on the participant and user for a participant principal.
2. Re-reads the assignment through the tenant-scoped `:active` read at
   `DateTime.utc_now()`, never the actor's `at`. It then requires the participant
   and user to be `ACTIVE`, as `actor/3` already requires.
3. Requires the same assignment, principal, tenant and organization, and
   checks the capability against the fresh definition.

Every `Board` write calls it on entry and again inside its transaction,
immediately after any lock it waits on: the trip row for `transition`, the
per-load advisory lock for `add_stop`. The mutation and its audit event use the
fresh actor.

How the two orders work out under PostgreSQL READ COMMITTED:

- **Authority change commits before the share lock.** The re-read sees it, so
  the write is refused.
- **Authority change attempted after the share lock.** The `UPDATE` waits on the
  share lock until the mutation commits, so it is ordered after the write.

The trip lock is taken before the share lock and the authority writers never
take the trip lock, so these two lock sets form no cycle. The order-after case
is argued, not tested: no test pauses a transition between its share lock and
its commit.

Tenant and organization isolation are unchanged. The re-read is tenant-scoped,
and the fresh actor must name the same organization. Signed business admission
is untouched, and no Board write gains a new path.

## Validation

- Mutation checks. Each of the following was applied separately and caught by
  `BoardAuthorityConcurrencyTest`; every mutation was then reverted:

  | Mutation | Tests failing |
  | --- | --- |
  | In-transaction re-check removed | 6 |
  | Standing check removed | 2 |
  | Capability checked on the cached snapshot | 1 |
  | Entry check reverted to the snapshot | 1 |

- At `7539063d`:
  - `BoardAuthorityConcurrencyTest`: 11 tests, 0 failures, seed 0. Together
    with `BoardConcurrencyTest`, 14 tests, 0 failures in each of five repeated
    runs.
  - The full Dispatch suite with `--include integration` and the eventstore
    configured: 2 doctests, 475 tests, 0 failures.
  - `mix compile --warnings-as-errors` and `mix openapi.check` pass.
  - `mix credo --strict` on the changed files reports one finding, which is
    present on main before this change.
  - `mix format --check-formatted` fails only on `mobile_session_test.exs` and
    `mobile_devices.ex`, which this change does not touch.
- Local environment: PostgreSQL 16 with PostGIS 3, Elixir 1.19.0, OTP 27.3.4.

## Proof Bank correspondence

The model assumption is now restated as a runtime obligation with
evidence. It remains **unverified**, and implementation refinement remains
**not established**.

Proposed pilot entry (method `:conformance`, no Lean theorem; the abstract
model has no grant state to prove it from):

```elixir
%{
  id: "D-GRANT",
  statement:
    "A transition is authorized by the selected role assignment as committed at the " <>
      "serialized mutation boundary, not by a cached actor snapshot or caller instant.",
  runtime_test: "apps/dispatch/test/dispatch/operations/board_authority_concurrency_test.exs",
  test_marker: "revoking the selected assignment denies it",
  source_anchor: {"apps/dispatch/lib/dispatch/operations/board.ex", "authorized(actor, capability, lock: true)"}
}
```

`ProofBankCore.DispatchPilot` is **not on main**. #253 merged into #241's head
branch after #241 had merged, and main carries only #236's scaffold. This entry
therefore cannot be added to the pilot from a PR against main. It is recorded here
for when the pilot lands. The pilot's D-ORG limitation ("no complete
equivalence proof for the actual organization/grant resolution") still applies.

## Open items (not addressed here)

- **Role-definition status.** `Dispatch.Access` ignores `role_definitions.status`,
  so a `SUPERSEDED` or `RETIRED` definition still confers its capabilities. Only
  a change to `capabilities_json` is covered above. Whether a superseded
  definition should keep authority until its reassignment plan runs is an owner
  decision.
- **Identity session expiry.** The `BizKit.Identity` session reference is
  checked once per request (`PortalSession`, `ResolveActor`). Board does not
  re-check it inside the transaction, so the remaining window lasts one request.
  User and participant suspension and the assignment's validity interval are
  re-checked.
- **Other Dispatch writers.** Examined in the follow-up below.
- **No refinement proof** relates the Lean transition relation to this code.

## Follow-up: the other Dispatch writers (2026-11-02)

The race needs a write that authorizes from the `Actor` snapshot and then waits
on a lock before mutating.

| Writer | Writes? | Waits on a lock after authorizing? | Finding |
| --- | --- | --- | --- |
| `Operations.Trips` | no (`mine/1` reads) | — | not affected |
| `Operations.LocationDemand` | no (`:pg` membership; reads consent) | — | not affected |
| `Accounts.Administration.grant/3`, `revoke/4` | role assignments, audit | yes, the per-organization advisory lock | **reproduced** |
| `Operations.Locations.begin_consent/2` | consent grant, audit | yes, the trip row lock | **reproduced** |
| `Operations.Locations.revoke_consent/2` | consent revocation | yes, the trip row lock | left on the snapshot on purpose (below) |
| `Operations.Locations.ingest/2` | location samples | no; each sample is authorized by its consent at acquisition | snapshot window bounded by one request |
| `StatusEventController` → `Declarations.declare/3` | status events, audit | only a same-key idempotency row, `lock_timeout` 3 s, and the waiter replays the first result rather than writing | snapshot window bounded by one request |

**Reproduction** at `e894f142` (tests only, `lib/` = main `fb3bb006`):
`writer_authority_concurrency_test.exs`, `--seed 0` → **6 tests, 4 failures**.
Each failure is an unauthorized success:

- An administrator revoked while queued on the organization lock still revoked
  another administrator. With only two administrators, the last-administrator
  guard refused this, but only by coincidence; with three, it succeeded.
- An administrator revoked while queued still granted a role.
- A stale snapshot of a revoked administrator still revoked another.
- A driver whose assignment was revoked while `begin_consent` waited on the trip
  lock still began location consent.

**Correction** at `99171887`:

- `Administration.serialized/2` re-authorizes `role_assignment.manage` with
  `authorize/3` (`lock: true`) once the advisory lock is held. It runs the write,
  and the step-up comparison, as that fresh actor; a refusal is `:not_found`.
- `begin_consent/2` re-authorizes `location.share.self` the same way after the
  trip lock.

At `99171887`: the 6 writer tests pass, also on three repeat runs, and the full
Dispatch suite gives 2 doctests, 481 tests, 0 failures. Two mutations were each
caught: removing the administration re-check failed 3 tests, and removing the
consent re-check failed 1. The credo findings on the changed `lib/` files match
main.

**Left on the snapshot, by design or bound.**

- `revoke_consent` stays as it is. Withdrawing consent only reduces what is
  shared, and refusing it because the participant's role lapsed mid-request
  would keep sharing alive.
- The Ash policy checks (`HasCapability`, `ActingOnSelf`, `PartnerScope`)
  evaluate whatever actor they are given. A writer that hands them a fresh actor
  inherits the fix; one that hands them a snapshot keeps a window of one
  request.
- **Owner decision (2026-11-02):** revoking a driver's role does **not** close
  that driver's open location consents. Consent belongs to the participant. It
  ends with the trip plus grace, or when the participant revokes it.
  `LocationsTest` "consent outlives the revocation of the role that began it"
  pins this.


## Owner rule: a driver's role ends at equipment check-in (2026-11-02)

Revoking a role that lets its holder drive is allowed only once the driver's
equipment is checked in. A role drives when it carries `assignment.read.self`,
the capability Board plans trips with. Dispatch has no check-in record, so
"checked in" means that **no active trip of the driver's in the organization
holds a vehicle or trailer**. If a later check-in event is added, it should
replace this predicate in `Dispatch.Access.Driving.equipment_out?/3`.

- `Administration.revoke/4` refuses with `:equipment_not_checked_in` while the
  equipment is out, unless another driving role of the driver's stays in force.
  Roles that do not drive are unaffected.
- `Board.transition/4` refuses to activate a trip whose driver no longer holds
  a driving role. Without this, an activation racing a revocation could still
  leave equipment out with no role behind it.
- **Serialization.** Revoke locks the driver's open trips `FOR UPDATE` before
  deciding. Activation holds its trip lock and then locks the driving roles
  `FOR SHARE`. Whichever commits first, the other sees it. Both take the trip
  lock before any role row, so they cannot deadlock. Both commit orders are
  tested.
- **Evidence.**
  - At `779af834` (tests only), the six rule cases fail: each is a write that
    should have been refused and went through.
  - At `05161366`, the full Dispatch suite gives 2 doctests, 492 tests,
    0 failures. The concurrency files gave 19/19 on three repeat runs.
  - Three mutations were each caught: removing the revoke rule (4 failures),
    removing its `FOR UPDATE` (1) and removing the activation rule (2).
  - Removing the `FOR SHARE` on driving roles is *not* caught. In the order where
    it would matter, revoke's trip lock already serializes the pair, so that
    lock is defence in depth.
- **Not covered.** The rule applies through `Administration`, the only
  revocation path the product exposes. The Ash `:revoke` action itself does not
  enforce it, so system or direct-data revocations bypass it.
