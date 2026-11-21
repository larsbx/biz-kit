# Source-bound Commercial Clearing — Unposted Accounting Preview

Date: 2026-11-15. Status: **inert accounting proposal**. No money movement,
contractual debt release, corporate agency admission, legal opinion or
financial writer is introduced.

## Design objective

Prioritize internal B2B commercial accounting and contractual clearing
calculations, with external bank/crypto payment rails left as residual
alternatives. The authoritative signed source obligations and V2 reservations
belong to the existing `CoopSubstrate.Log`; this increment **reads** them,
never changes them or creates a rival accounting/financial authority.

## Input boundary

`CoopSubstrate.CommercialAccountingPreview.preview(chapter, intent_id)`
reads a revision-stable local canonical `Log.gate` and requires:

1. An active `source_bound_proposal_v2` chapter profile.
2. An already admitted `CommercialSetoffIntentReservedV2` event with its
   authentic signatures and canonical event hash.
3. The precise source rows pinned inside the event and their SHA-256
   `source_terms_digest`.
4. Original-only, open, same-currency bilateral source obligations, each
   still reserved by the **same** intent.
5. Current source-event IDs/full hashes and immutable source revisions
   consistent with the canonical business projection.
6. Exact directional gross totals, nonzero setoff, and bounded arithmetic.

A caller-injected gate can be evaluated through `from_gate/3` only as an
untrusted pure computation. The public local `preview/3` rechecks the Log
head after reading, but this is **not** a source mutation lock, new
reservation, legal authorization or cross-node consistency claim.

## Exact source-level accounting arithmetic

Suppose A owes B 100 USD minor units and B owes A 60. The verified V2
reservation proposes offsetting 60 in each direction. The resulting
**hypothetical** accounting plan is:

| Actor | Unposted debit | Unposted credit | Amount |
| --- | --- | --- | ---: |
| A | Accounts payable | Commercial clearing control | 60 |
| B | Commercial clearing control | Accounts receivable | 60 |
| B | Accounts payable | Commercial clearing control | 60 |
| A | Commercial clearing control | Accounts receivable | 60 |

Each participant's candidate journal is separately balanced, and the
clearing-control debits and credits cancel per participant. The original
gross obligations total 160, proposed gross reduction is 120, and
the remaining 40 remains owed by A to B.

The candidate is **not** an authorized debit/credit, discharge, bank funds
receipt, spendable network credit, or proof that any counterparty's books
actually changed. It only computes what independent journals might look
like **after** a legally effective and independently evidenced discharge.

For multiple same-direction source claims, it allocates the permissible
bilateral offset in original-source-ID order using exact integer minor
units. It leaves a residual amount against each source, preserving trace
identity instead of silently manufacturing an unconditional replacement
payable. This FIFO allocation is deterministic but **not** proof of
globally optimal lawful clearing.

## Fences and negative controls

A preview must refuse a missing V2 reservation, a changed source assignment,
a source reserved to another intent, changed currency, missing/invalid
source record digest, stale/inconsistent direction totals, unsupported
historical lineages, or inconsistent arithmetic. It must leave the canonical
ledger head unchanged, and it must replay identically after restart.

The dedicated acceptance suite exercises real PostgreSQL-backed V2 signed
admission, current protected-profile fences, source-level accounting
conservation, unposted status, FIFO partial allocation and forged
reservation-map refusal.

## Remaining P0 acceptance requirements

- Independently verified commercial contracts/invoices and performance.
- Business-to-business principal identity and current agency grants.
- Jurisdiction/activity-specific nonprohibition, regulatory licensing and
  sanctions policy decisions, sourced and reviewed where applicable.
- A separate versioned legally effective source-bound *discharge* event
  with strict source-level serialized finality, approval evidence,
  no-double-discharge and partition/recovery controls.
- Real per-actor double-entry **posting** and matching independent
  reconciling books, plus reversals/disputes and tax treatment.
- Residual bank/provider settlement reconciliation only when required.
- Multilateral settlement requires a distinct authorization/finality
  contract; the present V2 commercial admission is bilateral only.

The preceding formal source-fence proofs model safety properties of
admission. They do not establish that these hypothetical journal entries
are a valid civil-law settlement or authorized monetary value transfers.
See #299 and #290 for the remaining acceptance ladder.
