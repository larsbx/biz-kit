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

## Scope: five obligations, two kinds of evidence

| Obligation | Abstract theorem or method | Actual runtime witness |
| --- | --- | --- |
| D-ORG | `BizKitDispatch.foreign_organization_refused` | `BoardTest`: foreign trip refused |
| D-STALE | `BizKitDispatch.stale_version_refused` | `BoardTest`: stale retry refused |
| D-TERMINAL | `BizKitDispatch.terminal_states_refused` | `BoardTest`: transition table; `BoardConcurrencyTest`: queued transition |
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
