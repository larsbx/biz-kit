# Exact pooled barter clearing: supplier needs, capacity and brokerage contracts

Date: 2026-10-26. Status: **pure matching and draft consent/accounting
preview**, not an operational exchange, registered company or settlement engine.

Tracks [#131](https://github.com/larsbx/biz-kit/issues/131), builds on
[PR #132](https://github.com/larsbx/biz-kit/pull/132).

## Why not only directed exchange cycles?

For a brokerage whose members contract to a common exchange plan, the useful
primitive is a **many-to-many supply/demand allocation**. A supplier can
provide several goods and request several other goods. Shipments may be
partial, a request may have many suppliers, and one provider may serve many
recipients. The number of members is not intrinsically limited.

`BarterCore.PooledClearing` accepts a pinned participant snapshot with
per-member `actor`, `revision`, `valid_until`, and typed `supplies` and
`needs` arrays. Every line identifies an **exact** `code`, `unit` and
positive integer quantity. A member may have multiple distinct goods; a
duplicate resource line inside the same side is rejected to avoid ambiguous
double counting. Whole snapshots are canonicalized by member and item keys
and SHA-256 hashed with unambiguous byte length prefixes.

For one resource r=(code,unit), construct an integer-capacity flow network:

- Source → supplier i has capacity `s_ir`.
- Supplier i → demander j has capacity `min(s_ir, d_jr)` when `i != j`.
- Demander j → sink has capacity `d_jr`.

Use deterministic shortest-augmenting-path maximum flow (integer exact
Edmonds–Karp) and output direct owner-to-recipient transfers, unmet quantities,
leftover supply and per-resource achieved flow. Integer capacities guarantee
integer results. No money, floats, cross-unit divisions or hidden conversions.

By the max-flow/min-cut theorem, the result maximizes **total delivered units
of each exact resource separately**, given this stated graph. Distinct
resources are not added into a fictitious overall measure; no claim is made
that a vector of separate maximum flows optimizes the barter's economic
consideration. The computation budget is a conservative estimate of O(V E²)
work; it rejects expensive plans explicitly, not by an arbitrary participant
or exchange-cycle limit.

This **routing** optimum is not a completed barter bargain: it may give some
participants more or less market value than others, and it does not impose
net in-kind value balance, mutually contingent fulfillment, feasibility of
multiple simultaneous physical commitments, stock ownership, freight timing,
jurisdictional law or full-bundle satisfaction. Those must be negotiated in a
versioned participant-governed charter and locally authorized contract.

## Draft temporary brokerage

`BarterCore.PooledBrokerage.draft/3` pins the entire optimized snapshot,
proposed company identifier, scope-limited charter digest/version and all
members receiving or supplying any chosen transfer, into a distinct immutable
agreement hash. The current allowed charter grants **matching and
reconciliation only**, with supplier-retained title and an explicit requirement
for external legal formation.

`pre_delivery_preview/3` checks that every selected member has a
corresponding evidence reference for the exact agreement hash and returns
conditional, **not-admitted** supplier-to-recipient in-kind entries plus the
outstanding unmet needs and unused stock. The response explicitly states
that negotiated consideration, legal company formation, authenticated
signatures, independent business-ledger admission and final performance
remain unverified.

A QR, public listing, gossip receipt, claimed proof reference or displayed
company ID is never agency authority or a signed membership contract.
Foreign messages cannot issue local inventory/accounting commands. A
consortium contract does not necessarily create a company or limited
liability, and a lawful intermediary/broker may require registrations or
licenses. Legal and tax treatment depends on jurisdictions and contract terms.

## Required follow-up after pure experiment

- Versioned owner-approved supply/need projections over existing
  ActivityPub/Iroh gossip with authentic publication and durable withdrawal.
- Verified legal authority of each member and company; private signed
  charter/member consents; timeouts, compensations, disputes and opt-outs.
- Explicit economic balancing and all-or-nothing/mutual conditionality
  under a newly versioned full optimization objective and constraints.
- Per-home-ledger conditional obligation accounting and InventoryCore stock
  reservation; allocations cannot double spend other active intents.
- Cross-node recovery and fulfillment/Dispatch custody evidence; partial
  shipments, returns and disputes.
- Exact optimization beyond separable resources (bundle satisfaction,
  logistical cost, valuations, substitutions, credit/financial effects)
  needs a bounded verified integer model, **not** the current per-resource
  max-flow proof.
