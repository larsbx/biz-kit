# ADR: Ledger-first commercial clearing and residual settlement

Date: 2026-11-03. Status: **Proposed architecture + pure V1 clearing preview**.
Owner: biz-kit commercial/barter capabilities. **Hawala financial custody,
credit, native postings, cross-authority clearing and finality remain exclusively
owned by `larsbx/hawala-core`.**

## Decision and priority

The primary product operation is **commercial ledger accounting and lawful
in-network discharge of real commercial obligations**. External bank or
cryptocurrency transfers are a fallback for obligations that cannot be
discharged internally. The design does **not** assume that calling a credit
"barter", "clearing" or "noncustodial" makes it exempt from money-transmitter
requirements. Substance, participants, controllable value and jurisdiction
remain controlling.

The ordering is:

1. Verify actual source contracts, performance, current owner, due date,
   currency, tax valuation and evidence of the real receivable/payable.
2. Reconcile separate actor-owned receivable and payable records.
3. Propose **bilateral mutual setoff** within applicable contractual, insolvency,
   currency, sanctions and jurisdiction rules.
4. Propose **multilateral contractual netting** where all relevant parties can
   legally approve assignments, releases, novations or equivalent discharge.
5. Match genuine reciprocal in-kind performance, with independent inventory,
   delivery and accounting evidence. Do not manufacture fictitious invoices.
6. Defer a residual obligation only pursuant to its contract or a valid amendment.
7. Prepare residual bank or licensed-provider settlement instructions for payer
   authorization, and reconcile independently verified provider evidence.

Step 1–6 are *not* a blanket legal classification as unregulated. Transferable
credits, cross-member spendable balances, guaranteed payouts, custody,
agent-directed disbursements and automatic third-party payment instructions
are separate capability classes, disabled without evaluated authority.

## Authority placement

- Each biz-kit node keeps its own signed, authoritative **business admission**
  history and its participant accounting projection; federation supplies
  proposals and attributable read models only.
- BarterCore produces immutable commercial clearing **proposals**, never
  financially authoritative or legally self-executing events.
- Participant signatures, current grants, local consent and contract/legal
  validation belong to the appropriate independently governed authoritative
  node. A ledger hash or URI is not a verified signature.
- Hawala alone owns monetary balances, financial clearing, native TigerBeetle
  commit, financial finality and provider execution permissions, as specified in
  the 2026-10-28 cross-repository extension and TB-first ADRs.
- External banks/providers execute authorized residual payments. A stored bank
  account reference gives no authority to instruct a transfer.

**There is no universal network bank account and no second financial writer.**

## Separate finite-state processes

### Commercial obligation (source-owned)

`proposed → accepted → performance_pending → performed/evidenced →
recognized → clearing_eligible → reserved → discharge_agreed →
discharge_legally_effective → journal_admitted → reconciled → closed`

Suspension, dispute, expiry and cancellation require explicit alternate paths.
An accounting receivable is not necessarily an undisputed enforceable claim.
Only the authority for that obligation may recognize or change it.

### Commercial clearing (proposal-owned)

`source_snapshot → eligibility_review → deterministic_candidate →
plan_pinned → approvals_pending → agreements_verified →
effective_discharge_evidenced → local_postings_admitted → reconciled`

The clearing plan is never itself a legal settlement. If one independent
participant has not approved a multilateral arrangement, the plan stays
pending. Missing replies/partial commit become held, not inferred success.
There is **no** automatic cross-node ACID.

### Residual external financial settlement

`residual_confirmed → provider_classified → payer_authorization_pending →
authorized_at_provider → pending → execution_observed →
provider_confirmation_verified → reconciled`

Rejected, returned, reversed, expired, disputed and unknown are first-class
outcomes. Provider acceptance is not proof of irrevocable payment.

## V1 implementation in this PR

`BarterCore.LedgerFirstClearing.propose/2` is an inert, dependency-free
integer-minor-unit clearing **preview**. Inputs are host-asserted claims with
unique source ID, revision, evidence reference, debtor, creditor, currency,
amount and expiry. Its assertion marker is **not a signature verification**.
No FX, transferable credits, custody or financial execution is possible.

The solver:

- Sorts the complete snapshot, partitions by exact three-letter currency and
  finds directed cycles with deterministic breadth-first paths.
- Subtracts the smallest amount on a selected cycle, repeating until no
  remaining cycle is found. It produces residual obligations.
- Builds double-entry **journal intents** in each affected actor's logical
  books: debtor debit AP/credit clearing control; creditor debit clearing
  control/credit AR. Each cycle cancels clearing-control per actor.
- Computes gross proposed reduction and residual amounts in bounded integers;
  binds the snapshot and reduction to a canonical hash.
- Exposes an independent recomputation check and rejects changed details.

A cycle of A→B 100, B→C 80, C→A 60 gives a preview of three 60-unit offsets:
240 original → 180 proposed reduction + 60 remaining. No money or actual
legally effective discharge has occurred.

**V1 is a deterministic cycle heuristic, not a proof of globally optimal
netting.** It cannot merge currencies or match unverified obligations.
A fourth-power conservative computation budget bounds the admission
workload; it is not an arbitrary participant-count or graph-length limit.

All returned entries remain `unadmitted_preview`. The PR has *no* execution
endpoint, transfer command, balance issuer, platform custody, real ledger
writer, finance adapter or new financial authority.

## Required correctness properties

| Property | V1 status | Complete acceptance gate |
| --- | --- | --- |
| Exact integer accounting; balanced journals | Pure test targets | Independently reconcile business books |
| Immutable source snapshot and deterministic replay | Pure test targets | Signed source revisions and replay across restarts |
| Ledger conservation and no unsupported money creation | Pure test targets | Authoritative independent postings |
| Current authority for each individual obligation | Not implemented | Validate identity, grants, signatures and legal evidence |
| Legal bilateral setoff and multilateral consent | Not implemented | Party-specific contract verification and release evidence |
| No double discharge or overallocated obligations | Not implemented | Serializable reservations, fencing, idempotency and conflict proof |
| Atomic local journal admission | Not implemented | Signed event gate and restart/failure replay |
| Cross-node crash/partition recovery | Not implemented | Independent host adversarial tests |
| Residual settlement and returns | Not implemented | Provider-specific signed bank evidence and reconciliation |
| Sanctions, AML and licensing classification | Not implemented | Per-jurisdiction counsel-reviewed control gate |
| Legal tax treatment, audit and retention | Not implemented | Source/journal/evidence reconstruction and jurisdiction mapping |

Formal/software proof of double-entry arithmetic does not establish legal
enforceability, regulatory status or proof of funds.

## Acceptance route

1. Keep V1 pure and obtain hosted `barter-core.yml` format/test acceptance.
2. Add authenticated participant source snapshots and stale-source/revocation
   tests without allowing remote messages to write local business state.
3. Implement signed consent and a legal-effective-discharge evidence port
   (inert until independently approved).
4. Implement serialized local signed accounting admission and inventory/claim
   reservations, with restart and double-discharge negative tests.
5. Demonstrate two independently administered participants, failed messages,
   conflicting reservations, partitions and conservative reconciliation.
6. Gate provider adapters and international/crypto use by separate
   jurisdiction-specific financial permissions.

Linked authority documents:
- [Cross-repository ownership](2026-10-28-cross-repository-extension-and-hawala-capability.md)
- [Hawala node books](2026-10-28-hawala-node-books-postgres-tigerbeetle.md)
- [Pooled brokerage](2026-10-26-pooled-brokerage-clearing.md)
- [Commercial barter core](../../apps/barter_core/README.md)

## Explicit nonclaims

No state transition here releases debt, issues regulated credits, transfers
funds, performs financial clearance, verifies bank settlement, authenticates
foreign authorities, creates a corporation, or certifies compliance with any
federal/state/foreign financial law.

## V1.1: existing signed bilateral rail and FX-safe totals

The canonical business log already has `ObligationRecorded`,
`NettingExecuted`, `Finance.compute/3`, dual-party Ed25519 signatures
and serialized append-time netting recalculation. The new
`CoopSubstrate.CommercialSetoff.prepare/6` constructs only an **unsigned**
`NettingExecuted` proposal from current registered keys and current
obligations in the canonical Log gate. It does not sign, append, grant
financial authority or release a debt.

Existing Log admission can then accept a separately dual-signed event,
recompute its bilateral figures against current obligations, reject stale
terms and old keys, and durably close the pair's existing obligations
while recording one exact residual. Restart and replay must reconstruct
the same business state.

**Critical limitation:** the existing signed event encodes aggregate
netting figures, not exact source obligation IDs, trade-performance
evidence or legally effective discharge contracts. The proposed UI
source-ID list is **not in the signed envelope**. Existing member
registration is not proof of corporate agency or consent under foreign
law. Technical append acceptance is not legal clearance; the P0 source
provenance, contracting, sanctions and regulatory gates remain open.

`BarterCore.LedgerFirstClearing` now reports independent
`totals_by_currency` and never adds minor units from different
currencies. Legacy aggregate scalar totals are `nil` for a mixed
currency plan, populated only for zero/single currency. No FX occurs.

This increment reuses the existing signed business writer and leaves
Hawala financial custody, native postings and actual payment settlement
under `larsbx/hawala-core`. It adds no automated payment endpoint.
