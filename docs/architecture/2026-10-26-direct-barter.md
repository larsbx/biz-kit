# ADR: optimized participant-governed brokerage clearing for federated barter

Date: 2026-10-26. Status: **pure optimized matching + contractual previews, not
an incorporated company, contract-signing service or executing exchange**.
Tracking: [#131](https://github.com/larsbx/biz-kit/issues/131).

## Revised direction

No arbitrary four-party exchange limit. Suppliers publish what they provide
and require; independently operated biz-kit installations discover the public,
opted-in and origin-authenticated projections. Participants may enter a
**temporary, participant-governed brokerage vehicle by explicit contract**.
That brokerage can optimize and coordinate a collection of many-party
exchanges, including disjoint cycles, rather than requiring a buyer/seller
pair or an artificially small chain.

The brokerage is *not* a platform-owned merchant, global ledger or financial
intermediary. Its authority is granted by its members under a scope-limited,
expiring contract. The first contract profile is coordinating-only:
matching/reconciliation, no automatic title transfer, balance custody,
credit creation, unilateral admission or implied commission. Future charter
variants need explicit consent, jurisdiction-specific legal review and
additional domain contracts if the entity is to become principal, take title,
charge fees, insure performance or clear monetary claims.

A signed software charter **does not itself create or register a corporation**,
establish limited liability, satisfy broker licensing/tax requirements, or
provide a valid agency relationship under every jurisdiction. A genuine
company requires independently verified legal formation and organizational
authority. A contractual consortium is not silently labeled a corporation.

## Optimization model, first exact slice

`BarterCore.optimize/3` solves a **maximum-cardinality directed cycle
packing**, via minimum-cost bipartite assignment (Hungarian algorithm):

- Each advertised intent is one indivisible provider/recipient slot, with
  exact asset code, exact unit, positive integer quantity, owner origin,
  revision and expiry. An owner may publish several slots.
- A valid direct leg `i → j` transfers enough of `i.provides` to satisfy
  all of `j.needs`; source and destination must be distinct owners. No
  unit, currency, risk, utility or market-value conversion is inferred.
- An assignment maps each supply slot to one recipient slot, or its own
  inert, unmatched self-loop. The assignment is a permutation, so all active
  non-self edges form disjoint directed cycles, including cycles longer than
  four. Every active intent is used at most once per plan.
- A compatible non-self edge costs 0, a self-loop 1, an incompatible edge
  `n+1` for n active intents. All-self costs n; therefore no optimal solution
  includes an incompatible edge, and minimum cost is **exactly** equivalent
  to maximizing fulfilled intent slots. This does not maximize value, total
  physical units across different goods, fairness, or long-term welfare.
- The solver runs in polynomial O(n³) time. A configurable integer
  `work_budget` rejects expensive snapshots before matrix construction.
  This is computational admission control, not a four-entity/topology cap;
  the per-route/matched-participant count has **no hard cap**. Future
  implementations can decompose sparse graphs or use specialized solvers.
- Sort inputs by stable intent ID and choose deterministic tie outcomes.
  Each output includes exact legs, unfilled slot IDs, matching objective,
  an optimality label scoped to this indivisible-slot model, and a
  length-prefixed SHA-256 fingerprint of the **entire active input snapshot**
  and the selected cycles. Independent nodes may optimize different
  snapshots unless discovery freshness and snapshot identity are reconciled.

The model does NOT yet split heterogeneous stock across destinations, accept
bundled multi-item needs, enforce global inventory caps across an owner's
distinct intents, express substitutions/constraints/preferences, or optimize
network transport, time, negotiated valuations or service quality. The
general resource-allocation formulation is an integer/hypergraph optimization
problem; global optimality claims must stay scoped to the implemented model.
These capabilities require separately reviewed richer offers and optimization
policy, with compute budgets and exact certificates where feasible.

## Temporary brokerage contract and accounting

`BarterCore.Brokerage.draft/3` pins the optimal clearing plan to:

- A proposed HTTPS brokerage-company identifier and externally published,
  separately authenticated charter digest/version.
- A short lifetime, restricted matching-and-reconciliation authority,
  participant governance and supplier-retained title.
- A complete, deduplicated member set derived from every matched cycle.
- An immutable all-party `agreement_hash` binding the charter, plan and
  membership.

`pre_delivery_preview/3` requires exactly one **purported** matching consent
reference for each member and produces only unadmitted conditional delivery
entries. These references are not signatures and the draft is not legal
formation, membership acceptance, approval or a posting to accounts.

Operational host acceptance requires:

1. Authenticated, current, owner-consented discovery with explicit market
   snapshot provenance, opt-in needs publication and privacy filtering;
   gossip/public ActivityPub posts remain unauthoritative for commerce.
2. Every proposed member reads and individually **signs the same combined
   charter + optimized exchange terms**. Verify identity, authority,
   membership and evidence under applicable law; specify duties, liability,
   taxes, timing, compensation/disputes, governance and exit/wind-down.
3. Confirm lawful vehicle formation and separate broker-agent authority if
   a real incorporated company or licensed broker is required. Absent that
   gate, label it a proposed consortium, not an active company.
4. Each installation revalidates grants, product/capacity, reservations,
   stock revisions, overlapping intents, disclosure, regulatory constraints
   and signed all-party acceptance, then commits its **own** conditional
   entries and holds to its local signed ledger. No foreign actor has a
   local business-command privilege.
5. Exchange only after agreed readiness conditions are met. Direct physical
   handoffs run from original supplier to designated recipient, with
   FulfillmentCore/Dispatch evidence. The brokerage may route paperwork
   and reconcile obligations but does not automatically take possession.
6. Reconcile independent ledgers and durable receipts after partitions,
   partial performance, withdrawals and disputes. An optimizer result and
   unanimity of consent references cannot prove distributed atomic commit,
   physical delivery or settled consideration. Explicit compensation,
   insurance/security and dispute paths are future acceptance gates.

## Boundaries and follow-up implementation

`federation_service` and the existing `bizkit.marketplace.listing.v1`
remain unchanged; they publish discovery candidates only. Add versioned
need/supply projections, local disclosure adapters, broker-charter lifecycle
and authenticated negotiation over separate domain channels.

Reuse CommerceCore/InventoryCore/FulfillmentCore/SalesCore at their existing
authority boundaries. Reuse Hawala's high-level patterns for identity,
signed intent, receipts and reconciliation, NOT its money, balances, deposits,
credit, exchange rates or financial custody. A brokerage promising monetary
clearing, transferable credits or financial guarantees must pass independent
financial-domain and legal acceptance.

Regression acceptance must establish an exchange with >4 participants,
multiple disjoint cycles, maximum matched intent count against exhaustive
small-input reference, stable canonical terms under input permutations,
consent and charter tampering refusal, bounded compute, no stock execution,
and no implicit company formation or settlement.

Next P0 integration: **legally explicit charter schema → private signed
all-member agreement → local conditional-accounting/InventoryCore adapter →
two independent instances with failure/recovery and delivery evidence**.
