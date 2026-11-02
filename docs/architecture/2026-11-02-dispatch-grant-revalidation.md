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
- **Other Dispatch writers.** These still authorize from the actor snapshot and
  were not examined against this interleaving: `Dispatch.Operations.Trips`,
  `Locations`, `LocationDemand`, `Dispatch.Accounts.Administration` and
  `StatusEventController`.
- **No refinement proof** relates the Lean transition relation to this code.
