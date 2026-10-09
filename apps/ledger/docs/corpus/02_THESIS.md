# 02_THESIS.md — The Complete Line

Register: business/system terms (01). Concern: what the network is and why it wins. Constraints: 00.

---

## 1. Objective

```
maximize    Σₘ value(m) = patronage(m) + ΔNAV·shares(m) + rate_uplift(m) + wage(m)
subject to  C  (00_CONSTITUTION, Articles II–VI)
```
C is the accumulation mechanism, not its limiter: no speculation ⇒ no bust erasing NAV; sovereignty ⇒ no defection cascade; declared terms ⇒ trust ⇒ volume; evidence gates ⇒ capital never outruns demand.

## 2. Topology

```
dock(A) ─drayage→ yard(A) ═linehaul relay═→ yard(B) ─drayage→ dock(B)
(leased, 3rd-party)  (staging: drop & hook)         (staging)   (leased, 3rd-party)
```

**Clock decoupling.** Live-load joins the carrier's clock to the facility's clock synchronously — detention is structural. Staged drop-and-hook buffers the two clocks — staged, coverage-cleared endpoints remove the live-load detention *category* (yard/appointment exceptions surface as logged events, never silently); residual live-load endpoints are telemetry-priced (07).

**Driver theorem.** `∀ relay leg ℓ: length(ℓ) ≤ daily_range ⇒ driver(ℓ) sleeps at home.` Relay inverts long-haul turnover economics; the network drivers prefer wins the drivers, and freight follows capacity. Graduation units (05) on relay legs compound recruitment. This is the capacity moat.

**Completeness.** `service(A→B) ⇔ path(yard(A) ⇝ yard(B))` in the activated-city graph. Each activation adds O(n) lane pairs; activation cost stays per-node and evidence-gated:
`activate(city) ⇐ members(city) ≥ m_c ∧ flow_fold(city) ≥ f_c ∧ lease_gate(yard(city))` (03).

## 3. Middleman removal ledger

| Intermediary | Rent | Replacement | Home |
|---|---|---|---|
| Freight broker | 10–20% linehaul | Broker Face, open-book | 04 |
| Factoring | 1–5%/invoice | quick-pay on the strict receivables set | 05 |
| Load boards | subscriptions + opacity | aggregate lane graph | 07 |
| Insurance chain | commissions + float | group buy → captive as mutual pool | 06 |
| Landlord | rent | LandCoop; rent → member NAV | 04 |
| 3PL | markup | leased capacity at declared cards | 07 |
| Fuel/parts cards | spread | group purchasing | 03 |

Invariant (00 Art. IV.4): every captured margin resolves to declared member-visible splits.

## 4. Automation surface

Automated (A-tier): matching, staging, custody folds, billing, telemetry, coverage monitoring, underwriting packets, detention packets, allocation, netting. Human (lax-direction only): lease/charter/rate-card/ruling signatures, claim filing, sponsored introductions, governance. Headless invariant: zero regional operations staff — sentinels, folds, and members.

Every handoff in §2 is a signed event on an existing stream; `complete_line(load)` is replay-verifiable end to end without new event types. The custody chain **is** the product.

## 5. Properties

```
P1  ∀ participating load over activated, coverage-cleared stages:
    unbroken signed custody chain dock(A) → dock(B)
P2  ∀ relay leg: length ≤ daily_range under assignment policy
P3  ∀ activation: gate evaluated as pure function of the log
P4  ∀ removed-rent flow: resolves to declared member-visible split
P5  live-load detention category eliminated at staged, coverage-cleared endpoints
    (exceptions logged as events); residual live-load endpoints telemetry-priced
P6  member value folds (patronage, NAV, uplift) computable per member from the log
```

## 6. Open

1. daily_range policy; per-leg liability assignment at yard boundaries (06 extension).
2. m_c, f_c: federation-standard vs chapter-declared.
3. Cross-chapter leg pricing; netting as the settlement rail.
4. Cold-corridor bootstrap — **CLOSED by 12 §2**: corridor-pair outreach concentration; first activations arrive pre-paired. Retained for provenance.
