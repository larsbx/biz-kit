# ADR: Network-native Hawala capability across federated biz-kit instances

Date: 2026-10-28. Status: **Proposed; design only**.
Paired with [hawala-core ADR 0005](https://github.com/larsbx/hawala-core/blob/main/docs/decisions/0005-biz-kit-federated-hawala-integration.md).
Changing a proposed decision N1–N7 requires corresponding review in both
repositories. This elaborates [the shared-identity/scoped-authority
ADR](2026-10-28-hawala-shared-identity-and-scoped-authority.md) and
[the federated marketplace](2026-10-24-federated-marketplace.md); it is not
a change in production authority, regulatory status or deployment readiness.

## Goal and deployment topology

**Deep integration:** Hawala is a native, composable service plane at each
participating biz-kit instance. Its signed-identity, obligations, remittance,
merchant payment, credit, clearing, payout and ATM interfaces are reachable by
authorized biz-kit domain products, and instances participate as Hawala Iroh
peers. Keep `hawala-core` as canonical protocol/financial rules and support
non-biz-kit Hawala peers. There is no network-wide biz-kit ledger.

```text
             Federated biz-kit marketplace / ActivityPub (public discovery)
                       |                              |
                 Biz-kit instance A             Biz-kit instance B
                 Commerce, Eatsbot,             Dispatch, group buy,
                 domain workflows               merchant workflows
                       |                              |
                 Hawala capability              Hawala capability
                 host/adapter                   host/adapter
                       |                              |
                 Hawala Iroh peer <-----------> Hawala Iroh peer
                       |                              |
                 Authority for S_A?             Authority for S_B?
                       |                              |
                 Custody/ledger A?  <-- M6-C6 --> Custody/ledger B?
                              common decision/abort fence
```

## Paired decisions

**N1 — Native capability plane.** Provide a versioned `HawalaCapabilityV1`
host interface per participating installation for peer identity/session
verification, payment/FX quotation, immutable accepted terms, transfer and
transaction QR proposal, authority discovery/routing, status reconciliation,
receipt inspection and conflict/HOLD reporting. Prefer an independently
supervised `hawala-core` Rust network service exposing an authenticated,
versioned local port to Elixir; evaluate pure Rustler adapters separately for
pure validators. Neither the Rust service's existence nor API reachability
is permission to move funds.

**N2 — Separate instance and financial roles.** A biz-kit node can be home
to business products, Hawala peer, noncustodial routing node, authorized dar,
terminal operator or named scoped authority. User roles, federation presence,
Hawala identity, business grants, financial eligibility, custody mandates and
settlement authority are **different** claims. Nothing infers the latter from
the former. Installations may expose the Hawala UX without custody authority.

**N3 — One owner for financial semantics.** Hawala-core defines domain
invariants and versioned financial protocols. Biz-kit owns the host,
business command adapters, local grants, workflow/UI and ledger-correlated
business evidence. `commerce_core` owns orders, `group_buy_core` owns
conditional commitments, and Hawala owns financial obligations/custody and
the result semantics. Never fork a second money ledger in a commerce,
federation or generic `CapitalAccounts` module.

**N4 — Exactly one scoped authority for each financial fact.** Keep one
signed business ledger per biz-kit installation. Where ADR D5 is satisfied,
one named and legally authorized instance may order an explicit **scope S**
of Hawala credit lots, customer claims, collateral allocations and dar
exposure **inside its existing serialized append boundary** with all D5
atomicity, accounting, range, governance, formal and operational gates. Until
then, that node is only an adapter/client to an independent Hawala authority.
Remote biz-kit ledgers store only attributable evidence/projections, never
co-authorize or duplicate S's balances. There is no general cross-node
event-store bridge.

**N5 — Transport separation.** ActivityPub and the existing
`federation_service` handle public listing/discovery. The Hawala Iroh peer
network carries authenticated private financial messages over its own
signed/session-bound protocol. Gossip, cache inclusion, a seller `Offer`,
and a remote outbox delivery have **no** financial finality or authority.
M6-C6 requires a named common decision order and safe abort fence for
cross-authority reservations. M6-C7 remains synthetic and locally atomic;
do not label it distributed settlement.

**N6 — Domain workflow composition.** Expose a shared payment-intent
boundary to Eatsbot checkout, general `commerce_core` sales, Dispatch
billing, `group_buy_core` conditional pledges, gift-card/redemption and
remittance UIs. The domain initiates an immutable, signed correlation
between business revision, exact terms, authorized parties, consent, currency,
fees, funding provenance, attempt and destination authority. Hawala alone
decides its financial result. An authenticated `Committed(intent)` result
only permits the **one** scoped execution attempt when authorized; it is
not cash delivery, paid invoice, released escrow or final financial settlement.
Business completion waits for independently verified finality under explicit
rules. Durable outbox/inbox receipts, idempotency, dispute paths and
reconciliation handle cross-instance partial outcomes. No cross-node ACID
atomicity is asserted.

**N7 — Proof-driven rollout.** Formalize authority scope, transaction QR
consumption, exact double-entry balances, accepted FX/fees, concurrent
attempts, paired reservations, irreversible final commit/abort, failure
recovery and partitions in Lean/Quint before building production mutation
surfaces. Run the same generated conformance traces against Rust/Hawala and
the Elixir host. Use QR **only** for presented participant identity; key
bindings are explicit, proof-of-possession based and confer no financial
grant. Require signed-domain separation, exact i64/u64-safe encodings,
local authorization, independent custody/legal/AML/KYC and security reviews.

## Implementation allocation

| Location | Proposed responsibilities |
| --- | --- |
| `hawala-core` | Rust Iroh transport, signed QR/financial protocols, trust/obligations, custody/authority models, FX/ledger reference, M6-C6 coordination, terminal recovery, formal proofs and vectors |
| Biz-kit Hawala host/extension (new) | Supervision and authenticated service port, domain command mapping, local scoped grants, peer capability status, durable operation correlation, read-only projections and source attribution |
| `coop_substrate` | Signed business-event admission; **scoped** financial append only after full D5 gates, never by generic evidence ingestion |
| `commerce_core`, Eatsbot, Dispatch, `group_buy_core` | Domain-specific offers, checkout and obligations; invoke versioned Hawala interfaces without acquiring Hawala balance authority |
| `federation_service` | Opt-in public discovery and merchant advertisements, **not** customer private financial messages or financial commits |

No permanent cloned Hawala Rust logic in biz-kit. No requirement
to locate Hawala in biz-kit's Elixir umbrella: network integration is a
**deployed, versioned contract**, not repository co-location.

## Acceptance sequence

1. **Contracts + proof artifacts:** `HawalaCapabilityV1` typed port,
   authenticated caller/grant semantics, results (`Rejected`, `Held`,
   `Committed`), correlation IDs, exact bytes, no-authority property;
   complete paired D1–D3 vectors.
2. **Two installations + Iroh:** isolated configurations, authenticated
   endpoint binding, signed QR identity, read-only offer/evidence,
   restart/replay/partition tests. A third instance acts as a routing peer
   without financial authority.
3. **Synthetic integrated checkout:** one biz-kit commerce proposal, one
   Hawala test-only coordinated admission, owner-attributed signed receipts,
   delayed/out-of-order delivery, HOLD, abort fence and recovery.
4. **Scoped D5 financial host:** one durable append transaction enforces
   per-currency balanced postings, QR/attempt IDs, custody reservations,
   exposure, policy epoch and crash safety; Lean/Quint traces conform
   against the actual host and existing Rust reference. No shared-finance
   writer in other hosts.
5. **Live-release barriers:** independent real custody reconciliation and
   operator mandates; licensing, AML/KYC/sanctions, privacy, trusted hardware
   and independent security/legal review. Prototype tests alone do not
   authorize a production rollout.

## Open gaps (must close before Accepted)

This section is **identical** in hawala-core ADR 0005 and in biz-kit's
network-native Hawala record. Edit it in both, in the same change. A gap
closes only when its exit criterion is merged in both repositories. The
acceptance step it blocks cannot start before then. Steps refer to the
five-step acceptance sequence above, which both records number the same way.

### Protocol semantics

**G1. Finality states (N6). Blocks step 3.** "The required financial
state" that lets a business workflow advance is undefined. Without it, a
merchant cannot tell a reserved payment intent from being paid.
*Closes when:* a typed state sequence is specified. A minimal version is
`Proposed → Committed(intent) → Executed(observed) → Settled`, with
`Held` and `Aborted` reachable from every state before `Settled`. For each
state, the specification names:
- the authority that signs it;
- the exact signed bytes and their domain;
- what a relying instance verifies before acting on it.

Each consuming workflow (checkout, dispatch fee, group-buy release,
remittance) declares the minimum state it waits for.

**G2. Decision coordinator and liveness (N2, N5). Blocks step 3.** M6-C6's
"common decision order" across independent authorities is an atomic-commit
problem, so some party must provide the order. N2 lists no role allowed to
order decisions across scopes.
*Closes when:* N2 and N5 name a scoped **decision coordinator** role, with
mandate, keys and epoch fencing. Its liveness rules are stated:
- A participant may abort unilaterally only before it prepares.
- After prepare, coordinator failure leaves reservations in `Held`.
- The rules name who resolves a `Held` reservation, within what bound, under
  which mandate, and with what evidence retained.

**G3. Distributed commit model before orchestration (N7). Blocks step 3.**
Step 3 composes a cross-authority checkout, but M6-C6 and M6-C7 model only
one local journal.
*Closes when:* a Quint/Lean model of the cross-authority commit is merged.
It covers coordinator and participant messages, crashes and restarts,
timeouts, partitions, duplicate and replayed messages, and abort fencing.
It proves agreement (no two participants decide differently) and the
`Held` behaviour of G2. Its generated traces are the step-3 conformance
suite for the Rust and Elixir hosts.

**G4. Refunds, disputes and compensation (N6). Blocks step 3.** N6 cites
reconciliation and compensation without defining them. ADR 0003 forbids
unilateral reversal of a completed spend.
*Closes when:* refund and compensation are specified as **new** dual-signed
obligations, never as rewrites of committed ones. Dispute entry, evidence
retention and the adjudicating authority are named for each workflow in G1.

### Authority, trust and privacy

**G5. Authority discovery and trust pinning (N4, N5). Blocks step 2.**
There is no global registry. The ADRs do not say how a relying instance
learns which authority orders scope S, or how it pins that authority's
keys, epochs and successor.
*Closes when:* a signed, versioned authority descriptor is specified,
covering scope, keys, epoch, custody profile, successor and fencing policy.
Relying-party pinning and rotation rules follow ADR 0001: local trust
policy, no global revocation. Discovery may advertise a descriptor, but
only the pinned policy confers trust.

**G6. Capability port authentication (N1). Blocks step 1.** N1 says
calling the host confers no authority, but leaves two questions open: how
the Rust service authenticates its Elixir caller, and how a biz-kit grant
maps to a permitted Hawala operation.
*Closes when:* the local port has mutual authentication, a version
handshake and per-call grant binding. The service re-verifies every
participant signature itself and never accepts the host's assertion of
consent.

**G7. Disclosure model (N6). Blocks step 2.** N6 binds "permitted
disclosure" into the correlation record, but no model defines it.
*Closes when:* the specification states, per role (merchant, routing peer,
coordinator, authority, observer), which fields of terms, receipts and
status each one may see. Routing and observer peers see no amounts or
counterparties beyond what routing needs.

### Keys and identity

**G8. Participant keys stay on participant devices (N1, N7). Blocks step 1.**
The capability host must never hold participant identity, consent or
transaction-QR keys. Accepted terms and transaction QR are signed on the
customer's or merchant's own device, in line with biz-kit's rule that no
server signs in a person's name.
*Closes when:* N1 and N7 state this. A host-side test refuses any request
to sign on a participant's behalf. The host's own node and operator keys
stay distinct from participant keys.

**G9. Signing-domain guard and fixture integrity (ADR 0004 D3). Blocks
step 1.** The interoperability vectors exist, but three follow-ups remain:
- **Runtime guard:** nothing yet prevents a biz-kit signer other than
  envelope signing (device statements, capability documents) from using a
  key bound to a Hawala identity.
- **Fixture drift:** the two fixture copies can diverge silently.
- **Wording:** `0x68` is described as "not a CBOR header". Read as a CBOR
  initial byte it is a text-string head (major type 3), never a map head
  (major type 5).

*Closes when:*
- Binding a key to a Hawala identity excludes it from every non-envelope
  signer.
- Both tests pin the fixture's SHA-256.
- The wording states both readings.

**G10. Exact money encoding (D5.3, N7). Blocks step 4.** N7 requires
"i64/u64-safe" encodings without choosing one.
*Closes when:* the specification fixes one encoding for amounts on the wire
and in the biz-kit ledger. Either amounts are capped at 2^63−1 minor units
everywhere, or they use decimal strings with a canonical grammar. The
specification also publishes vectors at both range boundaries.

### Process

**G11. Lockstep text for N1–N7.** The paired N1–N7 texts differ in
substance. Only hawala-core's N1 rules out a universal operator, a central
server and a singleton registry. Only hawala-core's N5 requires retaining
locks and original IDs on `HOLD`.
*Closes when:* N1–N7 are reconciled into identical normative text, or one
record becomes normative and the other points to it.

## Relationship to existing decisions

ADR D4 means **no network-wide Hawala balance ledger**; it does not
prohibit Hawala functionality from running on every participating biz-kit
instance. D5 can make an instance authoritative for **one named S** only
when all safeguards are met. D6 governs bilateral settlement between
authorities. Thus deep network integration is consistent with
decentralization **only while authority stays explicitly scoped**.

This record is architecture/design, **not** evidence of implemented
distributed coordination, financial admission, custody, payout, or release
readiness.
