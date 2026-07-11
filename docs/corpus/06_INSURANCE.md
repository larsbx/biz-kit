# 06_INSURANCE.md — Risk & Coverage

Register: insurance/system terms (01). Concern: how the network stays covered and how coverage gates operations. Constraints: 00 Art. III.5 (bounded necessity), treasury policy 05 §6.

---

## 1. The staged path

```
Stage 0  group purchasing        — buying power pooled, no risk pooled; builds the loss-history corpus
Stage 1  fronting + group captive — per-carrier policies & filings via admitted fronting insurer;
                                    working layer reinsured to the member-owned captive
[shelved] own risk-retention group — re-opens only on stage-1 evidence (loss ratio, scale, capital)
```
Layering: L0 per-carrier deductible → L1 per-carrier policy + regulatory filing → L2 shared retention (captive) → L3 catastrophic excess (conventional reinsurance, bounded necessity; mutual-pool reinsurance preferred where capacity exists — the minimization must be demonstrable).

**Captive internal structure — mutual pool from day one** (09/F2): contributions as donations to the pool; declared management fee; declared surplus-distribution rules; deficits covered by benevolent loan from the operator. This realizes the exit path partially at stage 1, independent of the shelved terminal form. Reserve investment: treasury whitelist only (05 §6) — off-whitelist placement unrepresentable.

Per-carrier experience rating within L2: a loose operator's losses reprice that operator, not the pool. Assessments: capped by pre-declared schedule; over-cap assessment events unrepresentable. Filing constraint honored throughout: filings remain strictly per-carrier — pooling lives at L2, never at L1.

## 2. Coverage predicates (imported by 07 dispatch gating — single authority here)

```
tenderable(c, t)   ⇐ active(liability, c, t) ∧ filed(c, t) ∧ fresh(certificate, c, t)
operable(f, t)     ⇐ active(lines(class(f)), t)         — premises, warehouse legal liability per asset class
dispatchable(u, t) ⇐ active(GL ∧ garage-keepers/on-hook, operator(u), t)
```
Fail-closed: unknown/stale (> τ) ⇒ false. Revocation is automatic, strict-direction, atomic with detection — no gap states. Restoration is lax-direction.

Lines per asset class (leased infrastructure, 07 §4): dock/cross-dock — premises GL, warehouse legal liability; warehouse — WLL, premises; shop — premises, garage-keepers; fleet-as-lessor — contingent lessor liability. Relay-leg liability assignment at yard boundaries: open (02 OQ1).

## 3. Agents

| Agent | Function | Tier |
|---|---|---|
| CoverageMonitor | poll policy/filing/certificate status per insured entity; emit degradation; revoke capability atomically | A |
| CertificateAgent | issue own certificates deterministically from policy-of-record; verify inbound, graded (document-consistent vs issuer-confirmed) | A |
| RenewalAgent | T-90 assemble / T-60 review / T-45 submit / T-30 bind-or-escalate; submission whitelisted-fields only (data minimization structural) | A assemble / R submit |
| ClaimsAgent | first-notice packet within severity-tiered deadline (obligatory); evidence bundle with provenance; file/no-file with deductible and experience-rating math | A assemble / R file |
| CaptiveLedger | loss-fund accounting, experience rating, distributions/assessments | A compute / R declare |

N: negotiating fronting terms; settlement authority; captive investment decisions. Block: tender/operate/dispatch against a false predicate; altering issued instruments; unsigned external representations.

## 4. Guards
Lapse recurrence per insured (leaky bucket → symptomatic/structural classifier: reminder vs standing review); claims frequency per carrier (CUSUM → experience rating); notice-deadline performance (CUSUM — watches the agent); override rate (leaky bucket — chronic overrides mean the automated logic or the human is structurally wrong); external-endpoint pressure (token bucket).

## 5. Properties
```
P1  ∀ tender/operation/dispatch: predicate held with verification age ≤ τ at event time (auditable ex post)
P2  ∀ certificate issued: derives from an uncancelled policy-of-record on the same stream
P3  degradation ⇒ capability revocation in the same transaction
P4  ∀ assessment: amount ≤ declared cap (unrepresentable otherwise)
P5  ∀ external representation: human-signed with resolvable provenance
P6  notice latency ≤ severity deadline ∨ logged override with reason
P7  certificate issuance and ledger computations are pure functions of the log
P8  reserve placements ∈ treasury whitelist
```
Adversarial: forged inbound certificate; stale-verification tender; over-cap assessment; clock-skew backdating; poisoned document parse (parses land as graded verification events, never authoritative state — 08 §7).

## 6. Open
1. τ per predicate conjunct (filing polls vs policy status — different freshness economics).
2. Insurer integration surface: API vs portal vs email-in — decides how much A-tier is real on day one.
3. Severity taxonomy for notice deadlines: adopt insurer's vs define and map.
4. Countersignature threshold on overrides (separation of duties on the discouraged path).
5. Roadside-work liability (service units on member equipment): mutual-pool question at captive formation.
