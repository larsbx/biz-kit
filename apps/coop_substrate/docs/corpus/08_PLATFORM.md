# 08_PLATFORM.md — Event Substrate & Enforcement Mechanisms

Register: engineering (Elixir/BEAM, cryptography). Concern: the mechanisms every other layer imports. Runtime context: agent framework on the BEAM (supervised process-per-agent, state-machine loops, scheduled jobs); local-first P2P sidecar for discovery, NAT traversal, and replicated log sync; trusted always-on relay cluster internally clustered, untrusted member edge speaking only the sidecar wire protocol.

---

## 1. Event substrate

- Envelope V1: canonical signed events; dual hash-chains (global + per-stream); Ed25519 throughout; CBOR on the wire; versioned schema profiles for unknown fields/migration.
- Streams are sovereign by owner (member, entity, chapter) and classed by disclosure (07 §5): stream assignment is a function of event type — misclassification is a type error.
- Append-only, unbounded retention; signed per-owner log export is the external-evidence and compliance path.
- Privileged boundary: every lax-direction event (leases, charters, rate cards, rulings, claims, external representations, constant declarations) terminates its provenance chain in a human signature. Strict-direction operations (detection, revocation, folds, packet assembly) are unprivileged.

## 2. Structural enforcement doctrine

`invalid ⇒ unrepresentable`. Prohibitions are encoded as type/validation predicates on events wherever possible; behavioral prohibitions that can't be typed are block-tier at the agent boundary. Consequences: stratagem resistance (a disguised structure is rejected at construction, not audited after execution); side agreements are void (only on-stream obligations are enforceable in governance).

## 3. Autonomy tiers

`A` act · `R` recommend (human signs) · `N` not-yet (gated pending ruling or maturity) · `block` structurally impossible. Tier assignment follows direction: strict-direction defaults A; lax-direction is at most R; protected-objectives class (00 Art. VI) is forbidden to every capability — no delegation chain reaches it. Capabilities are typed and attenuating along delegation chains with grade ceilings; proposer/verifier objective independence where duties separate.

Three mechanisms extend A-tier reach without weakening the human-provenance rule (assignments in 10):
- **Standing authorization envelopes**: a human-signed policy event declaring bounds (rate corridors, lanes, exposure caps, counterparty classes, per-period limits). In-envelope acts are strict-direction executions of the envelope; the provenance chain terminates in the human at the *policy*. Out-of-envelope ⇒ escalate R. Envelopes are versioned, amendable, revocable; revocation is atomic with effect.
- **Veto-window execution**: for periodic attestation-adjacent acts under standing power-of-attorney where law permits — the assembled act is notified at T, executes at T+δ absent objection. Notification proof is part of the event; δ per act class is a charter constant.
- **Grade-conditioned tiers**: `tier(act) = f(min grade(inputs))` — an act derived wholly from ≥G2 attested inputs may hold a higher autonomy tier than the same act on G0 claims. Attested provenance substitutes for human re-verification, not for human authorization.

## 4. Attestation grading

`G0 claimed → G1 document-consistent → G2 attested → G3 corroborated (≥ k independent)`; grades decay: `grade(e,t) = min(awarded, decay(t − last))`; per-use floors `G_min(use)`. Staleness bounds τ per entity kind; StalenessSentinel sweeps, decays, and suppresses. False attestation is a censure event against the attester's conduct standing, with provenance — never a mere data correction.

## 5. Guards & estimators

No fixed windows: per-guard online estimators — CUSUM (regime change: dwell, claims frequency, coverage ratio, deadline performance), leaky bucket (recurrence: lapses, overrides, attestation follow-ups, score-brigading), EWMA distributions (telemetry), token bucket (external-endpoint pressure). The symptomatic/structural classifier is deterministic and fail-closed: symptomatic → remediation loop; structural → standing review or design change. Guards watch agents as well as members (override rate, notice latency): chronic overrides mean the automated logic or the human is structurally wrong — either is worth catching.

## 6. Privacy mechanism ladder (minimum necessary mechanism)

```
plain signatures      — bilateral transactions (both parties see the data): the default
k-anonymity gate      — aggregate publication with contributor floor
additive HE           — collusion-resistant aggregates (pool statistics, exposure totals)
zero-knowledge proofs — co-opetitor confidentiality with portable third-party verifiability
nullifiers            — network-wide uniqueness without disclosure (receivable double-pledge)
```
Escalate only when the lighter rung demonstrably fails the confidentiality or corroboration requirement; de-escalation is equally a finding. Current assignments: nearly everything bilateral; telemetry k-gated with HE as declared upgrade; receivables nullifier is the one live ZK application.

## 7. LLM boundary

Self-hosted open-weight models by default; frontier models only under zero-retention terms as bounded necessity; models see structure, not raw member data (whitelisted-field submissions, redacted parses). Model output is never authoritative state: every parse lands as a graded verification event carrying the raw-artifact hash — auditable, reversible. Poisoned-document injection is a standing adversarial case. Every bounded-necessity usage here (frontier models included) is declared with a **dated migration trigger** (member/volume threshold and target date) and reviewed under 09 §3 — necessity that stops being demonstrable lapses the permission.

## 8. Coordination & contention

Coordination-cost taxonomy: single-writer state · bilateral handshakes (dual-signed) · contended resources serialized by the resource owner (load owner for tenders; capacity owner for allocations) · network aggregates (§6). Obligation events (assignment, discharge attestation — 05 §1.2 rail) ride the same dual-signed bilateral rails; funds never do (money-transmission boundary). Invariants stay local; no global consensus. Mobile edge constraints honored: push via platform relays; always-on relay cluster provides availability.

## 9. Verification doctrine

TDD with property tests as forcing functions; every layer document ships replay-checkable properties (`fold(log) ⇒ identical state`) and an adversarial suite; determinism requirements are explicit (billing, matching, NAV, telemetry, zakāt, netting are pure functions of the log). Phase gates: the canonical signed event protocol passes before anything builds atop it; spike reports before dependency commitments; no long-term single-operator-key dependence (threshold custody deferred until scale warrants — premature cryptographic overbuild is itself a defect).

## 10. Open
1. Estimator constants per guard (chapter-tunable vs federation-standard).
2. HE upgrade trigger metric for k-starved chapters.
3. Key rotation and social-recovery UX for member edge keys.
4. Cross-chapter replication policy for commons streams.
