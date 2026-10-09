# 12_ONBOARDING.md — Coast-to-Coast Onboarding Engine

Register: engineering/system terms (01). Concern: the data, pitch, and pipeline that convert the national universe into members and capacity. Imports: harness handoff (11 §3), grading/τ (08 §4), autonomy (10), corridor activation (02 §2). Tracks: D/L/Y per current priority.

---

## 0. Spine rule

```
universe → enrich → score → outreach → interview (11) → sign (H5, once) → activate (gated)

leads      : national, ingested from public data      — coverage is coast-to-coast on day one
activation : corridor-gated, evidence-driven           — capital and service follow folds (02, 03)
∀ pitch claim: resolves to a fold ∨ a declared term    — marketing is honest by construction
```
The funnel is national; the network activates corridor-by-corridor. Data leads capital by design.

## 1. The lead universe (data requirements)

| Track | Source | Contents | Grade @ ingest | τ |
|---|---|---|---|---|
| D carriers | FMCSA census (MCMIS/SAFER) | every DOT#/MC#: power units, drivers, address, phone, operation class — filter 1–20 units | G1 | monthly |
| D carriers | FMCSA L&I | insurance status, filing history — recent-lapse and new-entrant flags | G1 | weekly |
| D carriers | new-entrant registrations | authority < 24 mo: the mortality-valley cohort, highest-need pitch | G1 | weekly |
| L drivers | no public census — paid channels (CDL boards, social) + referral loop | campaign-response events only | G0→G2 on contact | live |
| Y yards | county assessor/parcel APIs, industrial zoning, listing scrapes, satellite lot detection | parcel_ref, acreage, surface, owner of record | G0–G1 | quarterly |
| Y yards | **Google Places (enrichment only)** | operating paid lots, marketplace-listed lots, contact/hours, review-derived pricing & underserved-demand intel | G1 at query time | live; **license: store place_id only — never the bulk universe (P7)** |
| Y yards | FMCSA carrier addresses × parcel join | carriers who *own yards* — dual-pitch leads (member + capacity) | G1 | monthly |
| Y docks/3PL | warehouse directories, association rosters, listing data | facility kind, doors, operator | G0–G1 | quarterly |
| S2 shippers (deferred) | manufacturer/distributor registries | held until Face live | G0 | — |

Enrichment joins: census × L&I × parcel × facility-graph commons; dedupe on DOT#/parcel_ref/geohash. All ingest A-tier under source-license predicates (scraping terms, rate limits — token buckets per source).

## 2. Scoring & corridor prioritization

```
score(lead)      = w · [need(lead), fit(lead), corridor_value(geo(lead))]
corridor_value   = f(lead_density(A) × lead_density(B), lane_flow_prior(A→B))
activate_next    = argmax over corridor pairs — the funnel's own density chooses expansion order
```
Corridor-pair gating (02 OQ4) resolved operationally: outreach concentrates where *both* ends are seeding, so the first activations arrive pre-paired. Need-signals ranked: recent lapse (coverage-sentinel pitch), new-entrant (survival pitch), single-truck (back-office pitch), yard-owning carrier (dual pitch). Scoring is a pure function of the log (P4).

## 3. The pitch (persona × message × proof artifact)

| Persona | Message | Proof artifact (a fold, not a promise) |
|---|---|---|
| Carrier owner | keep the broker spread; nights returned; open-book; equity accrues | live open-book statement; recovered-accessorials case; stake-view |
| Driver | **home daily** (relay); own a stake; graduate to your own authority | relay-leg map for their region; stake-view; graduation instrument terms |
| Yard owner | monetize idle asphalt; per-drop terms; no term commitment | demand fold for their geohash; declared per-drop card |
| 3PL/dock mgr | fill windows; evidence-attached operations; one counterparty | flow fold; custody-chain sample |

Pitch discipline (structural): every quantitative claim in outbound material compiles from folds or declared cards — a pitch asset containing an unresolvable claim fails build (P1). Honesty isn't tone; it's a type check. Referral is the premium channel: invite = sponsorship = admission event — the viral mechanic and the vetting mechanic are the same event, and sponsor standing exposure keeps growth quality-weighted.

## 4. Outreach automation

- Sequences (email/SMS/voice) A-tier inside **compliance envelopes**: CAN-SPAM/TCPA predicates, DNC screening, quiet hours, per-source and per-recipient rate limits; opt-out is atomic and permanent (P2). Compliance is a validation layer, not a policy memo.
- Personalization from enrichment folds (their lane, their lapse date, their parcel) — relevance from data, not volume.
- Terminal node of every sequence: harness interview handoff (11 §3) — outreach feeds discovery feeds fixtures feeds funnel; one budget, three outputs.
- Paid channels (Track L, and interview recruitment generally): opex, no fixed liability, evidence-gate compatible (03 P5) — spend freely; only signatures wait for folds.

## 5. Activation gates (per persona; all-A onboarding, one signature)

```
carrier : doc parse → graded events → default envelopes → H5 sign → tenderable(c) holds
driver  : qualification folds complete → H5 → assignable within sponsor/incubator path
yard    : listing → G2 on security bits before any loaded staging → bookable
dock/3PL: prospect → underwriting fold accrual → lease at G₁→₂ only (03; marketing never signs)
```
Onboarding time target: minutes of human attention (theirs), one signature (theirs). Everything else is parse, fold, and default envelope.

## 6. Chapter spawning

Leads are national; chapters instantiate where density crosses m_c: chapter-bootstrap kit = charter templates + constant defaults + envelope defaults from harness findings. Founding-member cohort for a new chapter is drawn from the interviewed (G2-known) leads of that geography — chapters are born pre-vetted.

## 7. Properties

```
P1  ∀ outbound claim: resolves to fold ∨ declared term; unresolvable claims fail asset build
P2  opt-out atomic, permanent, honored across channels; post-opt-out contact unrepresentable
P3  ∀ outreach act: within compliance envelope (DNC, quiet hours, rate, consent class)
P4  scoring, corridor ranking, and activation gates are pure functions of the log
P5  ∀ activation: persona gate predicate held (tenderable / DQ fold / G2 security / lease gate)
P6  funnel provenance end-to-end: member record resolves to source, sequence, interview, consent
P7  source-license predicates on every ingest; rate limits per source (token bucket)
```
Adversarial: purchased-list contamination (provenance required — unlicensed sources unrepresentable), lookalike-lead inflation of corridor scores (dedupe + identity attestation), pitch-asset drift from stale folds (assets rebuild on fold change; staleness τ applies to marketing too), referral farming (sponsor exposure + corroboration threshold), opt-out evasion via channel switching (P2 is cross-channel) — fail closed.

## 8. Open

1. Source licensing per dataset (FMCSA data is public; parcel API terms vary by county; listing-scrape terms need per-source counsel review — R once each, H3-shaped).
2. Voice-agent outbound legality per state (two-party consent, AI-disclosure statutes) — compliance-envelope constants, counsel-gated.
3. w (scoring weights) and corridor thresholds — operator-tunable within governance-declared bounds vs fixed constants.
4. Honorarium budget split between interview recruitment (11) and pure lead-gen — one budget line, measured by cost-per-activated-member, not cost-per-lead.
