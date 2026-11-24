# Commercial Signed Source Lineage — Formal Safety Plan

Status: **proof and signed-log fixture correspondence candidate**, pending
exact-head hosted Lean/Quint and PostgreSQL acceptance. PR #345 was merged;
this continuation is reconciled against current main and its protected
source-bound reservation profile from PR #351. No contractual discharge
or financial settlement is authorized.

## Scope

PR #345 derives an original signed-core digest and monotone source-revision
history from the canonical local `CoopSubstrate.Log` fold.

The target mathematical property is **non-requalification of an assigned
or discharged commercial obligation as an original-only source**.
This prevents assignment-out-and-back or legacy clearing residuals from
silently acquiring source-origin privileges.

## Lean universal obligations

`formal/lean/BizKitCommercialLineage.lean` models the effect of assignment,
direct discharge, legacy netting and observation on a single business source.

The intended theorems cover:

- Recording starts as original-only, open, revision 1.
- Every assignment, discharge, or legacy netting transition loses the
  original-only classification.
- Once lost, original-only status cannot be regained by ANY finite
  sequence of modeled transitions, including assignment out and back.
- Revisions never decrease under any finite sequence of transitions.
- A closed source cannot be reopened by the modeled transitions.

The theorems quantify over arbitrary source-state values and finite change
histories. They do not prove correctness of canonical hashing,
`CoopSubstrate.Membership` implementation, legal contract validity,
external source authenticity, or financial postings.

## Quint bounded adversarial controls

`formal/quint/commercial_lineage.qnt` models one source, three action
categories and restart stuttering. Its safety invariant binds
`revision = 1 + assignments + closedTransitions`, original-only eligibility
to the initial revision, and closure to a terminal status.

A deliberately unsafe control restores `originalOnly = true` during a
second assignment, which **must violate** the invariant after a reachable
transition. Additional nonvacuity witnesses require assigned, assigned-back
and closed histories, so "safe" is not merely an initial-state result.

The model assumes the canonical appender is serialized and that all relevant
source-changing events are faithfully represented. Cryptographic proofs and
legal authority are outside the model.

## Runtime correspondence acceptance

The companion PR #345 adds PostgreSQL-backed tests over actual signed event
history, including assignment-away-and-back, current open claim closure,
legacy residual derivation and exact rebuild after restart.

Passing Lean and Quint **does not establish a refinement theorem** between
these source models and the Elixir production implementation. Runtime
adversarial tests, source lineage reconstruction, and independent
exact-revision acceptance remain separate required gates.

The authoritative discharge and legal classification requirements tracked
in issue #299 remain open; no source-proof accomplishment should be reported
as a licensed settlement, accepted funds, or money transfer.

## Reconciliation against current main (November 15, 2026)

This branch preserves all current-main protected admission, procurement,
and formal proof modules and adds the historical model and fixture slice
without rewriting `CommercialAdmission` or weakening legacy-event fences.
The six fixture histories are generated from the exact Lean `replay`
semantics and compared with actual signed, durable source-history projections
on a non-protected chapter, including restart and refused duplicate claims.
Protected chapters retain the PR #351 source-reservation controls.

The model is still a read-projection correspondence exercise; it does not
prove the current `CommercialAdmission` V2 source reservation refines the
Lean model, nor does it verify enterprise agency, independently authenticated
trade performance, legally effective discharge, banking access or tax/legal
classification. Those remain separate acceptance obligations under #299.
