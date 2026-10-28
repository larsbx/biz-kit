# ADR: Cross-repository extension contract and network-native Hawala composition

Date: 2026-10-28. Status: **Proposed; architecture only**.

Companion proposals: [hawala-core ADR 0006](https://github.com/larsbx/hawala-core/blob/main/docs/decisions/0006-biz-kit-extension-host-boundary.md), [Eatsbot product ADR](https://github.com/larsbx/eatsbot/blob/dev/docs/modules/decisions/pages/biz-kit-interoperability-and-source-ownership.adoc), [d-patch ADR-0015](https://github.com/larsbx/d-patch/blob/main/docs/adr/0015-biz-kit-extension-and-hawala-client-boundaries.md), and [school-ops decision 0007](https://github.com/larsbx/school-ops/blob/main/docs/decisions/0007-biz-kit-content-authority-and-extension-contract.md).
A link to a proposed ADR is not evidence it has merged.

## Context

The [modular business platform](2026-10-24-modular-business-platform.md) already distinguishes portable capabilities from domain products. [SchoolOps](2026-10-23-school-ops.md) has a platform-hosted backend with pinned upstream curriculum; Dispatch's server is developed here while d-patch retains clients; the imported Eatsbot backend coexists with a separately evolved and currently production-authoritative Eatsbot repository. Their application and release contracts are not uniform.

The merged [Hawala shared identity/scoped authority ADR](2026-10-28-hawala-shared-identity-and-scoped-authority.md) and hawala-core ADR 0004 establish D1–D6. The *open* native Hawala proposals [biz-kit #173](https://github.com/larsbx/biz-kit/pull/173) and [hawala-core #42](https://github.com/larsbx/hawala-core/pull/42) propose N1–N7. This ADR aligns the wider application ecosystem without accepting those pending financial decisions, duplicating Hawala's protocols, or opening a production settlement path.

## Decision

### P1. Biz-kit is a reusable, federatable platform, not the canonical home for every product

Develop the common platform kernel, shared capabilities and platform-hosted domain backends in biz-kit. Keep independent clients, source-content repositories and separately released products outside the umbrella when warranted. Physical co-location is not a prerequisite for conformance.

One independently governed biz-kit installation has one authoritative signed **business** admission history for facts it owns. ActivityPub federation distributes advertisements and attributed projections, not authority, financial finality or a network-wide business database.

### P2. Specify a versioned application-extension contract

Introduce a platform-owned, versioned logical contract, **BizKit.ExtensionV1** (proposed name, not an implemented Elixir module), covering:

- Stable extension identifier, contract and implementation versions, supported compatibility range and dependencies.
- Declared capabilities and required grants; declarations **never** confer permission.
- Domain-owned commands, event schemas, projection inputs, required authorization, and command-to-authoritative-writer mapping.
- Migrations, activation/deactivation, health, failure/retry, idempotency and replay semantics.
- Optional external service endpoints and their authentication, authorization and version negotiation.
- Exact conformance fixtures for validation errors, source attribution, upgrade/downgrade compatibility and negative authorization cases.

Use an Elixir behaviour/manifest for platform-hosted applications and semantically equivalent authenticated wire contracts for separately deployed products. A shared name does not imply equivalent cross-process atomicity. Start with compile-time integration and controlled activation, **not** arbitrary runtime code loading.

Reject an extension that imports a reusable foundation package back into its product implementation, registers itself as authorized merely by listing permissions, or directly writes another domain's authoritative facts.

### P3. Document one canonical owner for each domain implementation

| Concern | Source and authority |
| --- | --- |
| Shared task, agent, business identity/grants and business admission | biz-kit reusable packages and each installation's authorized event append gate |
| Dispatch backend, Ash policy and server OpenAPI | `biz-kit/apps/dispatch`; d-patch's `central/` is a frozen compatibility snapshot |
| Dispatch Android and client conformance | `larsbx/d-patch` |
| SchoolOps platform domain and workflow logic | `biz-kit/apps/school_ops` |
| Curriculum, assessment text, pedagogical source revisions | `larsbx/school-ops`; biz-kit consumes immutable pinned content revisions |
| Eatsbot standalone product, independent deployment and current production writer | `larsbx/eatsbot` until an explicit reconciled cutover; the imported biz-kit copy is not an independent competing production authority |
| Hawala Iroh protocol, identity evidence, obligations, credit, financial custody/clearing and authority contract | `larsbx/hawala-core` |
| Hawala host lifecycle, local biz-kit grants, correlation, source-attributed read models | A **new** biz-kit Hawala integration extension; **no** second financial kernel |

A future Eatsbot source-ownership migration requires explicit code lineage, tests, release acceptance, and state/replay parity. This ADR does **not** choose or perform that migration.

### P4. Hawala is a native capability plane, not a generic platform writer

Participating biz-kit installations may host an independently supervised Rust/Iroh Hawala service behind a versioned, mutually authenticated local **HawalaCapabilityV1** port, once its protocol and transport gates have passed. That port is **not** the general BizKit.ExtensionV1 contract: the former speaks Hawala-defined financial semantics; the latter integrates domain applications.

Hawala remains valid for non-biz-kit peers. Keep private Hawala traffic on its native authenticated Iroh protocol, separate from public ActivityPub listings. QR is the sole *presented participant identifier*; local biz-kit principal bindings are explicit, and grants, custody mandate, financial eligibility and signing consent remain independent.

The host never stores participant private identity, consent or transaction-QR keys or signs on their behalf. The pure `hawala-capability-port` admission implementation merged in [hawala-core #43](https://github.com/larsbx/hawala-core/pull/43) is reference logic, **not** a deployed transport or money authority.

### P5. Authority is scoped and outcome semantics are not interchangeable

- Business orders, seller-home group-buy commitments, delivery proof and task changes use their existing authoritative business admission.
- Hawala alone specifies financial intents, credits, postings, custody, clearing and signed financial result semantics. A business ledger may retain independently verifiable Hawala evidence; retention is not settlement.
- Under D5, a biz-kit installation may eventually act as **one named financial authority for an explicit scope S** only after all original accounting, serialized atomicity, integer range, grant/governance fence, formal trace, custody, regulatory and security gates hold. **D5 is disabled by this ADR.**
- For distinct authorities, Hawala's M6-C6 coordination applies; partial/uncertain effects remain `HOLD`. Do not assume cross-node ACID, or turn synthetic M6-C7 reference tests into claims of distributed settlement.
- A committed **intent** is not paid, executed, cash-delivered, escrow-released or settled. Requiring domain-specific finality state and verification is a prerequisite to advancing a business completion state.

Do not regress the canonical seller-home group-buy escrow evidence admission recorded in [the October 26 implementation ADR](2026-10-26-group-buy-canonical-escrow-admission.md). Signed external evidence admitted by seller-home is still not proof of actual provider custody or payment execution.

### P6. One cross-repository compatibility and proof gate

The platform owns a versioned conformance matrix and pins exact tested revisions for biz-kit, Hawala, Eatsbot, d-patch and school-ops. Required lanes:

1. Application-contract version negotiation, dependencies, permission refusal, replay and event/schema backward compatibility.
2. SchoolOps pinned content IDs, source hashes, editorial readiness and scoped task admission (never infer learner attainment from completed staff tasks).
3. Dispatch server-first generated OpenAPI synchronization, device/session/revocation behavior, offline outbox and acceptance against the actual biz-kit backend.
4. Eatsbot portable build, release boot, pricing/order/fulfillment compatibility, idempotency, production-owner protection and explicit cutover criteria.
5. Hawala Rust/Elixir signed-byte golden vectors and signing-domain isolation (paired open [#41](https://github.com/larsbx/hawala-core/pull/41)/[#172](https://github.com/larsbx/biz-kit/pull/172)); fail-closed authenticated port, no host-signed consent, stale epochs and duplicate requests.
6. Lean/Quint-generated traces for financial scope, common terminal decision, fencing, crash/restart, partitions and reconciliation before any financial mutation or real-custody operation.

Maintain distinct statuses for **specification**, **pure proof**, **synthetic acceptance**, **deployed interoperability**, and **regulated/live operation**. CI cannot substitute for custody, legal or independent security review.

## Rollout and non-goals

1. Review this ADR with the four companion proposals and reconcile the open N1–N7 pairs' documented G1–G11 gaps. Do not silently make their different wording normative.
2. Publish a typed extension manifest/wire schema and make SchoolOps and Dispatch reference implementations; keep integrations initially nonmutating or behind current authorized admission.
3. Complete cross-repo identity vectors, authenticated Hawala service port, durable replay and biz-kit grant mapping. Use two independently administered biz-kit processes, two Iroh peers and a noncustodial router in test.
4. Resolve Eatsbot's long-term source ownership only after regression and production parity; do not cut over from this document.
5. Permit any Hawala scoped financial writer only after all D5 and pending N1–N7 financial proof/operational gates are satisfied.

No application migrations, production authority cutovers, network-wide ledger, new custody system, live payment rail or financial endpoints are authorized here.

## Verification for acceptance

Reviewers must check the paired five ADRs for an identical owner/authority matrix and compatible contract terms. Later implementation PRs must add failing-then-passing negative tests for unauthorized domain writes, host-as-participant signing, stale grant/epoch, cross-app duplication and financial-finality confusion. This ADR is **Proposed** until those enforceable contracts and repository-specific conformance paths are reviewed.
