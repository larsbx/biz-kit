# Proof Bank Dispatch pilot — recover merged branch and bind current-grant evidence

Date: 2026-11-03. Status: **candidate correspondence; no implementation refinement proved**.

## Why this integration PR is necessary

Original [PR #253](https://github.com/larsbx/biz-kit/pull/253) is marked
merged, but it was merged into the feature-branch base of #241 after #241
reached main. On main at `3cd35c168b50a6ab95bec64a86d6bdb90e0eec0e`,
`ProofBankCore.DispatchPilot` and its CI workflow were absent. This PR
restores that missing work against **current main** instead of relying on
stacked-branch merge status.

The later [Dispatch authorization fix #262](https://github.com/larsbx/biz-kit/pull/262)
is already in main. The actual defect was reproduced with independently
committed PostgreSQL sessions and was repaired by revalidating the current
selected role inside the write transaction. It does not supply an Elixir-to-Lean
refinement theorem. Issue #254 is closed on the strength of the described
runtime repair, not a formal proof badge.

## Scope: six obligations, two kinds of evidence

| Obligation | Abstract theorem or method | Actual runtime witness |
| --- | --- | --- |
| D-ORG | `BizKitDispatch.foreign_organization_refused` | `BoardTest`: foreign trip refused |
| D-STALE | `BizKitDispatch.stale_version_refused` | `BoardTest`: stale retry refused |
| D-TERMINAL | `BizKitDispatch.terminal_states_refused` | `BoardTest`: transition table; `BoardConcurrencyTest`: queued transition |
| D-VERSION | `BizKitDispatch.commit_increments_version` | `BoardTest`: version increment and stale retry |
| D-AUDIT | `BizKitDispatch.commit_appends_exactly_one_audit` | `BoardTest`: lifecycle audit |
| D-GRANT | **No Lean theorem; runtime conformance** | `BoardAuthorityConcurrencyTest`: selected grant revoked while trip row locked |

The model `formal/lean/BizKitDispatch.lean` represents a pure transition.
It assumes the actor was admitted under the required authority. The real
`Dispatch.Operations.Board.transition/4` calls
`Dispatch.Identity.PrincipalResolution.authorize/3` and uses PostgreSQL
locking. The model does **not** establish actual Identity session validity,
database locking, SQL transaction atomicity, permission changes in flight,
global operator exclusivity, or authorization of adjacent Dispatch functions.

A proven abstract transition theorem and a passing selected runtime test do
**not** logically imply the entire implementation refines the model.

## Reproducible exact-head evidence

The dedicated workflow `proof-bank-dispatch-pilot.yml` runs jobs at the
**same literal source commit SHA**:

- **Portable core/linkage:** compile, execute candidate/negative tests,
  refuse missing model/code/test anchors.
- **Formal:** pinned Lean toolchain; full fresh kernel replay and axiom audit,
  pinned Quint bounded checks, and refutation of negative controls.
- **Runtime:** separate real PostgreSQL/PostGIS-backed integration tests for
  Board lifecycle, stale-row concurrency and selected-role grant revocation.

Each job logs `git rev-parse HEAD`. No automatic evidence-status promotion
is implemented. Job success is reported as a job success only; local
`ProofBankCore.DispatchPilot.compile/0` always produces `:unverified`,
`:not_executed`, `:needs_owner_review`, and `:inert` data.

The anchor audit is text-only. It cannot detect every semantic change; the
first-party characterization catalog and exact-head CI remain independent
change-detection layers.

## Further acceptance gates

1. Review owner-intended behavior and precise runtime assumptions.
2. Prove or justify the mapping of each model state and guard to actual
   Elixir/Ash/PostgreSQL operations, including concurrent commits and audit
   persistence; log a concrete gap if such a refinement is not yet possible.
3. Test the opposite lock ordering (grant update waits after the transaction
   has taken a shared grant lock); cover source/role changes and session
   expiry in related access paths.
4. Treat global driver-exclusivity as a distinct unresolved obligation:
   the four existing Lean theorems do **not** prove it.
5. Independently review exact-head hosted evidence and security/authority
   gates before considering a change to verification status or extension release.

This PR introduces **no deployment, permissions, financial authority,
business writes or marketplace activation**.

## Proposed correspondence at the committed transaction boundary

Source audit baseline: main `a6253c5e1fd34404845f5d6d1bdbfed44db6dccf`
(PR #292 merge). At the initial follow-up inspection, run
[41658597995](https://github.com/larsbx/biz-kit/actions/runs/41658597995)
reported formal, runtime, and portable-linkage queued. The rows below
distinguish source inspection and test coverage from execution results.

Project the state of one committed trip and its load. Use an injective ID
encoding for organization equality within the selected tenant. The tentative
linearization point for a successful operation is the outer PostgreSQL
commit. A snapshot taken inside that transaction can witness the pre-state
after locking, but its changes do not yet count as committed events.

| Obligation | Runtime projection and guard | Abstract result and runtime coverage |
| --- | --- | --- |
| D-ORG | Board derives the selected organization from the role. Tenant-scoped Assignment lookup follows `load_id`; the load carrier must match the selected organization. Compare organization IDs after tenant scoping. | Lean refuses differing organizations. BoardTest exercises a foreign trip. Tenant scope and organization equality are distinct runtime checks. |
| D-STALE | `assignments.version` maps to a natural number; `nil` maps to `none` and a valid integer to `some`. Board rereads after the trip row lock and Ash applies its optimistic lock. | Lean refuses mismatching explicit versions. Board tests cover stale retry, queued reread, and competing same-version cancellations. |
| D-TERMINAL | Map `PLANNED/ACTIVE/COMPLETED/CANCELLED` to the corresponding Lean constructors. Board and Ash guard action source. `endPresent` is timestamp presence. `terminalWritten` is projected from committed terminal transition history. | Lean refuses transitions from terminal states. Board tests exercise the transition table and a queued update against the committed terminal state. |
| D-VERSION | Successful Ash updates increment the version on the same row. Model exactly one increment per committed transition within the representable database range. | Lean proves the increment for abstract commit. Board tests check one increment after competing writes and no increment on rollback. |
| D-AUDIT | Filter committed audit rows by tenant, trip subject and the three transition event types. Map `assignment.activated/completed/cancelled` to their actions in trip commit order. | Lean proves one append per abstract commit. Board tests inspect lifecycle rows, winning event type, selected assignment ID, invisibility before commit and absence after forced rollback. A durable reconstruction of commit order across all writers remains open. |
| D-GRANT | Compare selected assignment ID, principal type and ID, tenant and organization. After the trip lock, `authorize/3` share-locks the assignment and definition and, for a person, participant and user. It rereads the interval, standing and capability at server time. Audit uses that fresh actor. | Authorization is a precondition of the Lean transition. PostgreSQL witnesses cover a revocation or capability change committing first, the writer waiting when Board locks first, and a subsequent denial. The HTTP test exercises an already-expired Biz-kit bearer session with a current grant and a live-session control. |

Lean admits a state change only by organization, source state and optional
version, once the actor is admitted. Runtime can additionally refuse for an
invalid session at entry, unavailable records, a missing driving role on
activation, Ash/database errors or other boundary conditions. The candidate
correspondence is one-way for successful **commits**, with failed or rolled
back database attempts leaving the projected state unchanged. The HTTP or
Board response is a separate observation. In particular, Board reloads the
load after the mutation transaction, so response failure alone cannot be used
as evidence of rollback.

## Remaining proof and acceptance work

- Review the projection and show every supported writer preserves it. Justify
  the SQL isolation and lock assumptions, including concurrent edits of the
  load organization, lock cycles, retries and related write paths.
- Decide the semantics for a source session or time-bounded grant that expires
  after admission while a write is blocked. HTTP authentication precedes Board,
  and the Board transaction receives no source-session credential. Row locks
  serialize database edits but do not freeze a clock. The expiry case in this
  suite is at request entry.
- Establish the durable audit history projection and atomicity across all
  supported write paths. The rollback control exercises one concrete path.
- Global driver exclusivity across all trips, writers and tenants is **not
  established**. PR #312 defines E1/E2/E3 and supplies adversarial PostgreSQL
  cases; at `21923592`, they pass while the stronger global-user and profile
  binding assertions are refuted. See the review packet and pinned receipts.
- Record exact-head hosted outcomes before acceptance. The Proof Bank packet
  remains unverified, and marketplace release remains gated by #242.

## Reproduce the focused evidence

Check out the exact review SHA in a clean worktree and record
`git rev-parse HEAD`. Use the workflow's pinned toolchains, locked dependencies
and PostGIS 16 service with the EventStore and Dispatch setup steps. From the
repository root:

```sh
bash formal/lean/check.sh
bash formal/quint/check.sh
cd apps/dispatch
MIX_ENV=test mix test --include integration \
  test/dispatch/operations/board_test.exs \
  test/dispatch/operations/board_concurrency_test.exs \
  test/dispatch/operations/board_authority_concurrency_test.exs \
  test/dispatch_web/operations_controller_test.exs
```

The forced outer rollback and the expired credential paired with a live
credential are runtime negative controls. The existing Quint counterexample
controls exercise model sensitivity separately.

## Driver-exclusivity review packet (#296)

[DRIVER_EXCLUSIVITY_V1.md](DRIVER_EXCLUSIVITY_V1.md) defines the present
per-tenant partial-index invariant separately from proposed mixed-profile and
global-user invariants. Its independently committed two-trip acceptance suite
covers both contender orders, commit/rollback, terminal slot release and
non-Board writers. At `f04dee64`, hosted formal/linkage jobs passed but runtime
tests were skipped after a prerequisite CommercialSetoff compilation failure.
After that repair, run 42110873119 at `21923592` passed all three jobs,
including 61 runtime tests with zero failures and both assertion-specific
limitation controls. The hosted receipt is pinned to that source revision.
The accompanying profile-binding patch is unapplied. No verification status is promoted.

The [global exclusivity Lean/Quint layer](FORMAL_EXCLUSIVITY_V1.md) proves
preservation under an abstract commit-time guard and refutes weaker guard
models. Identity binding, authority and atomic database correspondence remain
assumptions; these results do not close the runtime or refinement obligations.
