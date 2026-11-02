# Proof Bank first-party adoption — Biz-kit application baseline

Date: 2026-11-01. Status: **repository-derived draft intake only**.
Tracking: [internal acceptance issue #242](https://github.com/larsbx/biz-kit/issues/242).
Depends on Proof Bank B0 draft PR #236; not a deployed reasoning workbench.

## Internal-first policy

Before inviting marketplace submissions, the Proof Bank must first be used
against Biz-kit itself and every app presently in the umbrella. That gives
the platform a reproducible dogfood target and exposes the difference between
business intentions, formal models, runtime contracts and accepted authority.

The `ProofBankCore.Portfolio` module seeds 30 structured candidate blueprints:
one for the Biz-kit platform and one for each of its 29 app directories
(including the new ProofBankCore). For each component, the seed records a
**proposed safety invariant, a reference to its source identity, a proposed
verification method and a possible existing formal-model lead**.

Every seed remains `needs_owner_review`, `unverified`, and `inert`.
The source application mix file establishes an inventory location; it is
not evidence that the proposed invariant holds. Existing Lean/Quint model
files are research leads, not a proof of refinement from production code.
No seed is permitted to confer app permissions or publication eligibility.

## What to do in the workbench

1. **Discover** the platform and all 29 Mix apps; reject missing and unknown
   apps in CI. The inventory includes transitional/legacy packages so their
   retirement constraints remain visible.
2. **Interview** the component/domain owner to reconcile each draft invariant
   against actual behavior, missing business rules and authoritative sources.
3. **Classify** each requirement as a theorem target, bounded model property,
   runtime conformance check, or human review. Formalize the precise state
   and assumptions; mark unsupported cases unresolved.
4. **Construct/check** independent evidence pinned to exact revisions and
   full checker profiles; run regression and negative tests at that SHA.
5. **Trace implementation** from specification through executable adapters
   using existing ExtensionV1 and authority contracts. A model theorem does
   not certify an Elixir module without a justified refinement boundary.
6. **Accept internally** before approving outside plugin submissions, and
   re-audit whenever the app inventory or implementation revision changes.

## Initial review sequence

| Priority | Components | First review targets |
| --- | --- | --- |
| P0 | `biz-kit`, `biz_kit_extension`, `biz_kit_identity`, `coop_substrate`, `agent_core`, `agent_ops_store`, `task_core`, `proof_bank_core` | Current grants, exact signed admission, stale/revoked rights, execution boundaries, evidence and acceptance lifecycle |
| P0 | `dispatch`, `hawala_capability`, `inventory_core` | Organization boundaries, exclusivity, financial authority separation, concurrent reservations |
| P1 | `commerce_core`, `fulfillment_core`, `group_buy_core`, `biz_kit_composition`, `dispatch_core`, `barter_core`, `sales_core`, `marketing_core` | Pure invariants, command handoffs, replay and consent semantics |
| P1 | `school_ops`, `federation_core`, `federation_service`, `keel`, `biz_kit_cluster` | Content provenance, scope, federation and cluster authorization |
| P2 | `eatsbot*`, `spruce_goose` | Salvage and retirement without second writers or lost history |

These are review priorities, not proof or implementation-completeness claims.

## Acceptance and failure semantics

Run `ProofBankCore.Portfolio.audit_repo("../..")` from
`apps/proof_bank_core` to check all known apps are declared.
`ProofBankCore.Portfolio.compile_all()` returns candidate traceability
blueprints. This intentionally does not import application runtimes, read
private data, make network calls, load plugins or modify state.

Required acceptance before any formal status promotion:
- Domain owner approval of exact requirement revision and source assumptions.
- Independent Lean proof checks for supported claims; bounded Quint checks
  explicitly labelled bounded; reproducible conformance against the same
  exact implementation revision.
- Negative tests for scope failures, stale commands, duplicate/replayed
  requests, missing custody, failed admissions and model/implementation drift.
- ExtensionV1 compatibility and activation gates from PR #224/#225; no
  permissions from manifests, no automatic code loading.
- Original business admission for effects; Hawala/TigerBeetle remains
  financial authority. Legacy package retirement is separately gated.
- Reviewed evidence expiry/invalidation when specification or source
  revisions change.

A passing inventory audit proves only that the seed list matches the
checked-out Mix app directories. It does **not** prove the correctness of
any requirement, formal theorem, implementation, security policy or deployment.

## Next deliverable

An owner-review worksheet generated from the baselines, followed by a
read-only workbench API and review UI. The first proof/implementation
conformance pilot should use the existing Dispatch exclusivity model and
a second distinct capability such as InventoryCore or SchoolOps.
Keep separate verified, tested, unresolved and proposed statuses.

See [Proof Bank rollout](2026-11-01-proof-bank-rollout.md).
