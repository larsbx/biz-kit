# Commercial clearing: exact-source signed intent — 2026-11-08

Status: **inert signed business proposal increment**. This document is not
evidence of legally effective debt discharge, regulatory classification,
verified trade performance, corporate agency or financial settlement.

## Why this increment

The existing dual-signed `NettingExecuted` event cryptographically binds
aggregate bilateral netting amounts, **not exact original obligation IDs**.
The source-bound proof contract from merged PR #298 and the two-source
proof-reference slice from #340 remain distinct from the actual appender.
P0 issue #299 requires an authorized, source-fenced and evidence-validated
admission before commercial debts can be legally discharged.

The nearest safe increment is **source-bound, signed intent admission only**.
It exercises the existing single authoritative `CoopSubstrate.Log` append
gate without granting new settlement powers.

## Signed event

`CommercialSetoffIntentRecordedV1` has two required signatures, current
`party_a` and `party_b`, one canonical event ID, chapter and intent ID,
same-currency gross directional totals, exact setoff, complete lexically
sorted source list, and `source_terms_digest` over that canonical list.

Each source entry contains:
- Obligation ID.
- Current debtor and creditor participant IDs.
- Exact declared denomination.
- Positive integer amount in minor units.

The full source list is inside the **original signing bytes** of the event.
The digest is an additional internal consistency check, not a substitute for
signed source-event hashes. The source records themselves are still the
existing party-attested `ObligationRecorded` business facts and are not
independently validated invoices or shipping evidence.

## Serialized business append rule

`CoopSubstrate.Protocol.Validity` routes the event to
`CoopSubstrate.CommercialSetoffIntent.check/2`. This is inside the
existing serialized canonical Log append transaction, which already checks
envelope signatures, signer-role shape, stream binding and replay identity.

The gate refuses:
- Unregistered or stale signing keys.
- Reused `(chapter, intent_id)`.
- Missing or malformed pair roles, denomination or amounts.
- Unsorted, duplicate, missing or substituted sources (including a same
  aggregate amount represented by different original IDs).
- Incorrect source terms digest, directional totals or setoff.
- A single-direction or mixed-currency setoff attempt.

Only *current open pair obligations* are included in this event. Unlike the
existing aggregate-signed NettingExecuted, this event **does not close them**.

## Projection and recovery

Membership's canonical signed fold retains
`commercial_setoff_intents[{chapter, intent_id}]`, with the signed source
list and an explicit `signed_proposal_not_discharge` status. The projection
does NOT mutate obligations, receivables, financial balances or settlement
status. A changed event under the same intent is refused; canonical exact
event retries are idempotent under the existing Log semantics.

The signed ledger reconstructs proposals on restart and chain verification
remains the integrity check. Retained intent records are historical
observations, not active exclusive reservations. Multiple proposals may
compete for the same source until a future *separate* legally authorized
source-level discharge gate resolves them.

## Remaining P0 limitations

1. The source list is bound to the **current projected obligations** and
   does not include their original authoritative record event digests and
   revisions. The read-only `CommercialSetoffSources` can derive originals
   but does not itself install an atomic durable source-event fence.
2. `MemberRegistered` identifies a signing key; it is **not** proof that an
   individual is an authorized agent of the debtor or creditor business.
   This early admission is not business-to-business contractual authorization.
3. No independently authenticated invoice, performance, ownership, legal
   release, sanctions decision, jurisdiction-specific authorization or
   statutory setoff eligibility has been verified.
4. The historic `NettingExecuted` still permits its legacy aggregate
   matching. This new event neither fixes nor reclassifies that pathway.
5. A signed business proposal is **not** settlement and does not issue
   money substitutes, transfer custody or instruct a bank or crypto rail.
6. International or multilateral clearing requires separate signed
   agreements, source-level exclusivity and cross-node HELD recovery.

## Required next increment

A versioned discharge/admission type must bind exact original source-event
hashes, current source/agency/legal authority and source-level conflict
guards **within** the authoritative serialized append, while preserving
historic event replay and selectively disabling legacy aggregate execution
for the newly protected commercial profile.

Run the dedicated
`Commercial ledger-first clearing acceptance` hosted workflow, plus the
common ledger/consolidation regressions. CI success proves scoped runtime
behavior, not regulatory compliance.
