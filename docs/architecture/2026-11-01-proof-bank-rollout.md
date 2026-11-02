# Biz-kit Proof Bank — proof-driven application foundry rollout

Date: 2026-11-01. Status: **initial inert core scaffold; architecture and
follow-up gates, not deployed or security accepted**.

## Product and scope

Members propose an idea, complete an adaptive interview, review a structured
business specification, and approve an immutable version under explicit local
governance. The Proof Bank derives proof obligations and an implementation
contract; independent agents or humans implement competing candidate extensions.
Independent conformance evaluates candidates; the marketplace advertises
available versions; organizations select and authorize installations.

**A specification is not a running application, a model check is not a proof,
a proof is not proof that business premises are fresh, and a vote is not
execution authority.** Every actor, organization, revision, evidence source,
policy and promotion decision needs provenance.

### Placement and ownership

- `biz-kit/apps/proof_bank_core`: pure, independently vendorable blueprint
  validation/traceability and versioned domain-neutral contracts. This PR
  adds no runtime service, host grants or data tables.
- Future Biz-kit host adapters: approved specifications, interview custody,
  authenticated grants, immutable revisions, artifact hashes and current
  state. Do not add a parallel business event writer. Use existing
  CoopSubstrate task/decision/record admission for relevant human approvals.
- `AgentCore`: approved execution profiles for interview/agent builders and
  future proof search. An agent returns **candidate** artifacts, never approval.
- `BizKit.ExtensionV1`: *proposed and under PR #224*; the marketplace
  eventually targets that versioned manifest, capability, dependency,
  explicit activation and compatibility boundary, not a second plugin loader.
  Do not depend on unmerged code or claim runtime activation exists.
- Independent product repositories may contain implementations and clients;
  base specifications remain reusable portable contracts, not copies of
  business-owned source data. No new top-level repository is needed before
  a second genuinely independent consumer justifies extraction.
- Optional Lean/Quint tools and Mojo/MAX kernels live behind versioned engine
  adapters. CPU-only operation is mandatory; GPU acceleration has no authority.

## State and trust boundaries

```text
idea (untrusted)
  -> interview transcript (untrusted candidate)
  -> reviewed requirement set (versioned, human-approved by authorized gate)
  -> obligations (explicit assumptions, sources, method)
  -> proofs/checks (version-pinned evidence and negative findings)
  -> implementation contract (exact spec and extension version)
  -> agent implementation candidate (sandboxed, no domain-write access)
  -> independent conformance and security checks
  -> marketplace advertisement (discovery, not installation)
  -> selected, authorized extension activation (separate host gate)
```

Do not conflate `proposed`, `reviewed`, `approved`, `proved`,
`bounded_checked`, `tested`, `deployed` or `trusted`. A specification
revision must invalidate or recompute downstream proof, compatibility and
release eligibility as appropriate. Revocation, task/project scope and
membership are checked at approval and at each business-effect admission.

Every accepted proof claim must bind its exact proposition, assumptions,
imports, checker build, profile, immutable input and evidence bytes.
An LLM or compute worker cannot self-certify its generated proof. A verified
formal property is conditional on its encoded semantics and assumptions;
implementation conformance must separately establish a refinement or report
remaining gaps. Avoid `sorry`, unsanctioned axioms, and unverified oracles.

### Governance and marketplace separation

Votes may prioritize shared development, authorize funding or grant a
"community-maintained" label under an explicit governance charter. Voting
cannot grant database access, financial custody or production deployment.
Marketplace listings identify exact spec, artifact, publisher, provenance,
conformance and compatibility profiles. Installation requires independent
host approval, scoped grants, dependency checks and rollback. Federation
may advertise signed digests; remote claims require local verification.

### Data and authority

PostgreSQL stores durable accepted business decisions and evidence metadata
under the established admission contract; Redis is optional scheduling/cache
only. Financial facts remain owned by Hawala/TigerBeetle. ProofBankCore does
not write any of those systems. Private learner, customer, location, driver
or financial records are excluded from LLM/accelerator contexts unless
independently authorized through typed, purpose-bound read ports.

## Rollout gates

| Gate | Deliverable | Evidence needed |
| --- | --- | --- |
| B0 (this PR) | Portable, inert core with strict typed input and reference checks; standalone CI | Exact-head tests, independent vendoring, absence of side effects |
| B1 | Idea/interview UI, structured revision workflow, scoped human approvals | Tamper/stale/revocation refusal, exact signed decision bytes, provenance |
| B2 | Formal model/obligation generation, checker adapters | Soundness obligations, exact checker/profile/input pinning, adversarial proof fixtures |
| B3 | Independent implementation contract and agent-run submissions | Two distinct backend implementations, sandbox/egress gates, candidate custody |
| B4 | Dispatch first vertical slice, then nonidentical second domain | Domain authority and cross-domain conformance; no competing writers |
| B5 | Marketplace discovery, governance, federated advertisement | Vote-vs-grant separation, signature/provenance, install refusal, rollback |
| B6 | Optional Mojo/MAX GPU proof-construction backend | CPU/GPU exact semantics parity, whole-proof throughput/cost, safe fallback |

## Initial acceptance limits

This scaffold compiles a proposed **structured** spec to a deterministic
in-memory blueprint. The source interview may be incomplete or inaccurate;
the compiler checks field shape, references and obligation coverage, not
semantic consistency or mathematical validity. All compiled obligations
remain `:unverified`, and activation remains `:inert`. No persistence,
production API, user-facing wizard, Lean/Quint proof, independent code
verification, AI implementation, package activation or marketplace is
claimed.

Track follow-up integration through separate, gated issues. Retain the
accepted Biz-kit signed business ledger, `AgentCore.ExecutionPort`,
versioned extension manifest and existing single-writer boundaries.

## Source decisions

- [Modular business platform](2026-10-24-modular-business-platform.md)
- [Cross-repository ExtensionV1 and authority](2026-10-28-cross-repository-extension-and-hawala-capability.md)
- [Signed AgentCore runs](2026-10-24-signed-agent-runs.md)
- [Storage authority](2026-10-30-postgres-event-log-redis-consolidation.md)
- [Human signed decisions](2026-10-18-decide.md)
