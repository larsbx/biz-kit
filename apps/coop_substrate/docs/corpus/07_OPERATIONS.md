# 07_OPERATIONS.md — Registries, Custody, Facilities, Leasing, Dispatch

Register: operational/system terms (01). Concern: the physical network's data and workflows. Mechanisms (grading, streams, guards): 08. Coverage predicates: imported from 06 (single authority).

---

## 1. Spine

Headless ⇔ operational truth is derived, attested, staleness-bounded state on the chapter's replicated log:
```
state(chapter, t) = fold(events ≤ t)
usable(entity, t) ⇐ grade(entity) ≥ G_min(use) ∧ age(attestation) ≤ τ(kind)
```
No manually-maintained availability anywhere: occupancy, queue depth, on-call status are folds. Local-first queries against last-synced state with staleness surfaced, never hidden.

## 2. Asset registry (controlled assets)

Entities: **Yard** (slots, access, security bitset, physical constraints as capability gates, terms, listing class) · **YardSlot** (occupancy derived: `occupied ⇔ drops − hooks = 1`) · **Carrier reference** (master data on the carrier's sovereign stream; registry holds a projection; `tenderable` imported) · **Shop** (typed service-capability set; queue derived) · **ServiceUnit** (typed capabilities; coverage area; on-call derived; operator per 04 §4).

Asset ladder: `prospect → coop_leased → coop_owned ∥ member_owned`. Matching priority: `coop_owned ≻ member_owned ≻ coop_leased ≻ prospect-with-terms`. Prospect ingestion (public parcels, listings, member scouting) is A-tier at G0–G1; grade upgrades only by member attestation; grades decay (08 §4). Loaded-trailer staging requires ≥ G2 on security bits. Prospect records double as the acquisition target list — one dataset, two consumers.

## 3. Custody chains

One pattern at every possession boundary — signed, condition-attested interchange:
```
drop/hook (yard) · in/out (warehouse) · arrive/depart (facility visit) · window-worked (dock)
```
- Equipment is carrier-operated only (00 Art. II.4); yards host, never take custody; title may sit with the co-op as lessor (05 lease instruments) with exclusive operational custody at the lessee.
- Damage attestation only adjacent to a boundary event — retroactive claims unrepresentable. Disputes reduce to comparing adjacent condition reports.
- Cross-carrier relay handoffs: both signatures on the hook event.
- One chain, many consumers: occupancy, dwell, billing, staged-capacity revenue (04 §3), detention evidence (§6), collateral condition (05 §3), and `complete_line(load)` verification (02 P1).

## 4. Leasing operations (T2)

- Lease-in underwriting is evidence-gated: utilization fold (facility-graph flow + booking pressure + signed demand pledges) ≥ u_min; aggregate obligations ≤ L_max; required coverage bindable (06 §2). Execution lax-direction; renewal requires a fresh packet — zombie leases unrepresentable.
- Allocate-out at declared cards; `Σ allocations(f,t) ≤ capacity(f,t)` — overbooking unrepresentable; contention serialized by the capacity owner (08 §8).
- Every head lease must carry explicit sublease permission before any allocation (05 P3 lease validity).
- No guaranteed-throughput clauses shifting vacancy risk to members: the co-op's vacancy risk is what justifies the spread (00 Art. III.2).
- Exit discipline: CUSUM on realized coverage ratio; sustained under-run is a structural non-renewal signal.

## 5. Facility graph (third-party terrain)

Three disclosure classes, assigned at the event-type level — misclassification is a type error:
```
commons    facility facts (docks, scheduling interface, constraints, hours)   chapter-public, graded
telemetry  dwell distributions, detention rate, appointment integrity,
           treatment scores                                                    published ⇔ contributors ≥ k
edges      serves/lane/counterparty/contact — relationship data                sovereign; bilateral or aggregate only
```
- Telemetry folds are pure functions of contributing visit events; sub-k publication unrepresentable; privacy-preserving aggregation is the declared upgrade if k starves small chapters (08 §6).
- The aggregate lane graph (edge-hidden flow intensities) powers backhaul matching; introductions occur via the Broker Face (edge never disclosed; tender is ordinary bilateral) or sponsored introduction (edge-owner signed; sponsor takes surety-shaped reputational exposure, no fee).
- Facility telemetry is also lease-target underwriting (§4) and yard site selection: detention density targets yards, flow intensity targets docks/warehouses.

## 6. Detention recovery

Arrive/depart + appointment + freight-document references assemble per-visit claim packets (A-tier); demands on customers are human-signed (R). Individually: recovered billables. Collectively: detention rates price facilities into rate decisions. Architecturally: staged endpoints eliminate the category (02 §2).

## 7. Relay & staging operations

Leg assignment respects `length ≤ daily_range` (02 P2); yard handoffs are §3 interchange events; drayage and final legs assigned by capability + accuracy-grade ranked match with the declared fairness-floor weight (04 §5 I3). Facility work (dock windows, warehouse in/out) staffed per 04 §7 OQ2 — never by carrier drivers (block).

## 8. Agents (consolidated)

| Agent | Function | Tier |
|---|---|---|
| RegistryIngest | prospect ingestion, dedup by parcel/geohash, document verification → G1 | A |
| StalenessSentinel | τ sweep all kinds; grade decay; matching suppression | A |
| Match (yard/shop/backhaul/leg) | ranked candidates over folds; grade + staleness surfaced | A answer / R introduction |
| Booking/Allocator | reservations & capacity at cards | A within card / R new terms |
| CustodyAuditor | chain integrity per unit: alternation, no orphans, dwell anomalies → CUSUM | A |
| VisitFold / TelemetryPublisher | visit folds; k-gate; publication | A |
| DetentionClerk | packet assembly | A / R submit |
| LeaseUnderwriter / UtilizationSentinel | packets; coverage-ratio CUSUM; renewal gating | A / R execute·exit |
| FacilityOps | window scheduling, warehouse custody events | A within card |

Block tier: operations against false coverage predicates (live loads); edge data on commons streams; sub-k publication; off-card allocation; overbooking; carrier-driver conscription; custody-event editing.

## 9. Properties (consolidated)

```
P1  derived-state correctness: occupancy/queues/on-call are folds (replay ⇒ identical)
P2  custody alternation per unit; no orphan events; damage only at boundaries
P3  ∀ match result: grade ≥ G_min(use) ∧ staleness surfaced
P4  ∀ live-load operation: imported coverage predicate held (06 P1)
P5  ∀ lease: evidence gate ∧ L_max ∧ sublease permission; renewal ⇒ fresh packet
P6  ∀ allocation: on-card ∧ Σ ≤ capacity
P7  stream(event) = disclosure class(type) ; telemetry ⇒ contributors ≥ k
P8  ∀ introduction: edge-owner signature present
P9  matching, billing, telemetry, utilization are pure functions of the log
```
Adversarial: occupancy spoof (unsigned drop), retro-damage, edge exfiltration via crafted commons attestation, k-gate evasion by window slicing, treatment-score brigading, allocation race across replicas, forged visit without telematics correlation — fail closed or detected.

## 10. Open
1. Corroboration k and τ per kind; reservation economics (hold fees vs expiring holds).
2. Interchange-standard interop for non-member handoffs vs signed-event export as evidence.
3. Warehouse custody depth: WMS-grade item events vs pallet in/out.
4. Scheduling-interface automation (portal interaction per facility type) — separate spec.
5. Third-party head-lease terms embedding throughput minimums: per-deal counsel review (R).
