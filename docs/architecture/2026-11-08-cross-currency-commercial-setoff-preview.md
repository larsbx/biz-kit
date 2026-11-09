# Cross-currency B2B setoff: exact valuation, inert preview and authority boundary

Date: 2026-11-08. Status: **implemented pure preview; no signed discharge, regulated FX execution or favorable legal classification**.
Related: [scoped non-prohibition profile](2026-11-04-commercial-clearing-nonprohibition-profile.md), [ledger-first ADR](2026-11-03-ledger-first-commercial-clearing.md), source-bound security issue #299.

## Decision

Different denominations are **not prohibited in the product design**. They need distinct valuation and consent evidence. The legal question is determined from the actual operator, activity and jurisdiction, not from whether two obligations use the same ISO currency code.

The first cross-currency increment is a *separate, pure, unsigned bilateral preview*. It is not attached to legacy `NettingExecuted` or `CommercialSetoffProof`, both of which currently assume one denomination. Do not reinterpret either event's signatures as approving a conversion rate or source-specific cross-currency discharge.

## The difference between three operations

1. **Multi-currency bookkeeping:** store original principal-owned receivables/payables in their *own* currency, with no scalar sum across units.
2. **Negotiated contractual cross-currency setoff:** two businesses agree that part of one obligation may be offset against a differently denominated reciprocal obligation at exact valuation terms. The business-specific contractual effect and accounting postings require separate authentication and approval.
3. **Operator FX dealing, exchange, transmission or payment:** Biz-kit receives, exchanges or sends monetary value, acts for a payer in sending a transfer, issues transferable credits, or executes an FX trade. **None of these exists in the new module.** Whether a future product offers them and requires registration, licensing or a provider is an independent question.

A statement that no physical currency moved is **not** enough, by itself, to rule out regulated activities. In the United States, 31 CFR 1010.100(ff)(1) describes foreign-exchange dealers and (ff)(5) addresses money transmission, including value substitutes and a facts-and-circumstances analysis. State and foreign rules may differ. Relevant reference: https://www.ecfr.gov/current/title-31/subtitle-B/chapter-X/part-1010/subpart-A/section-1010.100. This ADR does not find that the operator is outside either definition.

## Exact arithmetic contract

Implementation: `BarterCore.CrossCurrencySetoff.propose/5`.

Inputs:

- **Two directly reciprocal source claims** belonging to the two business principals, with different currency codes, positive integer minor units, unique source IDs, revision, host evidence reference, validity and eligibility status. These are **host assertions only**, not signed source-history proof.
- **One negotiated positive rational**, with `base_currency`, `quote_currency`, `numerator`, `denominator`, `agreed_at`, `valid_until`, `evidence_ref`, and `agreement_ref`. The reference fields are host assertions, not authenticated approval. The ratio MUST mean **quote minor units per base minor unit**, not a free-floating major-unit FX quote. This allows explicit denomination scaling (e.g., USD cents versus JPY yen).
- **One unique intent ID** and an as-of time. No automatic price feed, mark-to-market, quote provider or unilateral rate selection.

Reject zero/negative/noninteger rates, non-reduced ratios (prevent equivalent byte representations), malformed/cross-assigned currency pairs, stale terms, float-based arithmetic, extra payment-authority fields and unmatched principals.

For reduced ratio `n/d`, with `Q` quote minor units owed A→B and `B` base minor units owed B→A:

```
k             = min(floor(B/d), floor(Q/n))
base_reduced  = k * d
quote_reduced = k * n
base_residual = B - base_reduced
quote_residual= Q - quote_reduced
```

The result is the **largest exact offset for the declared rational rate** and two source claims. If `k = 0`, refuse the offset rather than fabricate or silently round a fractional minor unit. Calculations never turn EUR minor amounts into a numeric "USD total" without a declared valuation rate and direction. The output retains independent, per-currency conservation records.

Example: A→B USD 1,000,000 cents ($10,000); B→A EUR 800,000 cents (€8,000); agreed **11 USD cents per 10 EUR cents**. Pure preview: proposed EUR reduction 800,000 cents; USD reduction 880,000 cents; remaining USD 120,000 cents ($1,200). **No currency changes hands and no legally effective discharge is inferred by the computation.**

The deterministic `terms_hash` covers both individual source IDs/revisions/evidence refs/parties/currencies/amounts/expiries, the full negotiated rational, evidence and agreement references, intent and observation time, and reductions. `verify_plan/2` recomputes from the candidate's own asserted inputs and requires exact equality. It does not consult authoritative source history: a freshly rebuilt candidate with substituted or fabricated but well-shaped assertions can verify. Hashing host assertions does **not** authenticate their real-world contents.

## Nonclaims and fail-closed profile

The result explicitly reports `status: :unadmitted_preview_only`, `consent: :not_verified`, `legal_classification: :undetermined`, `discharge: :not_executed`, `currency_exchange: :none`, and `financial_settlement: :none`.

The module does not produce signed event bytes, a journal entry, a debit/credit in Hawala, a bank command, FX execution, or a release/novation. It does not assume that a computed number itself proves contract enforceability, corporate agency, beneficial ownership or sanctions permissibility.

**Never route this proposal through the old single-denomination `NettingExecuted` rail.** Source-commitment event design and legacy bypass closure (#299) must precede *any* actual commercial discharge admission.

## Next bounded acceptance: actual contractual discharge

Separately develop a versioned cross-currency commercial business event on the existing serial business log, using the protections in #299. It must bind:

1. Every original source record and signed latest revision/hash/party/amount/currency, including assignment lineage or fail-closed refusal;
2. The exact reduced rational quote/base **minor-unit** ratio, negotiated time/expiry, agreed partial-release amounts, independent party consent to that valuation, and governing agreement terms;
3. Current company/authorized-agent grants and effective mutual contractual setoff, independently checked at the append gate;
4. Atomic source-level reservation/discharge, idempotent intent fence, concurrent-writer and restart safety, no legacy aggregate bypass;
5. Independent **per-business** journal valuation (each actor's functional currency and book value, FX differences, taxes and reporting) without an automatically asserted single global total;
6. A narrowly supported jurisdiction/activity non-prohibition determination, with `undetermined` blocking an irreversible effect. No platform-operated value transmission or exchange unless a separately approved regulated provider/capability is introduced.

Cross-border, multilateral, transferable-credit and operator FX services are **distinct follow-up profiles**, not necessary to support a domestic pure cross-currency preview. A bilateral contract denominated differently is not automatically a regulated FX business, but its real operator activity must be reviewed.

## Reproducible negative controls

`apps/barter_core/test/cross_currency_setoff_test.exs` covers exact 11:10 two-currency reduction and conservation, partial minor-unit offsets, no-silent-rounding refusal, tampered sources/revisions/rate/terms, expired/future/noncanonical rates, nonreciprocal or malformed parties, same-currency routing, mutated output, and numerical bounds.

These are *software arithmetic and assertion-shape tests* only. They are not proof of independent consent, legal permission, accounting finality, or a currency-market quote.

## Lean-first arithmetic and independent bounded comparison

The [cross-currency proof bank](../../proof_bank/cross_currency_setoff/README.md)
adds 40 universal Lean theorems with explicit proposition contracts and an axiom
audit. Coprimality derives the common-multiplier form for **every** integer pair
obeying the rate equation, so maximum-offset claims quantify over all feasible
exact integer offsets. Per-currency conservation, integer residuals, rate
uniqueness, refusal, source preservation and inert output effects are separate
registered obligations.

The independent Quint model enumerates integer pairs directly and compares all
2,916 bounded arithmetic cases against Lean and the actual Elixir implementation.
Another 992 deterministic boundary cases compare Lean and Elixir. Source and
agreement controls are finite fixtures; no exhaustive temporal protocol check
or whole-Elixir refinement theorem is claimed. The runner checks clean Git-head
source bytes, fresh compilation/kernel replay, proof-placeholder rejection,
behavioral source mutations, all 55 Barter tests and the scoped formatter repair.

The dedicated workflow checks out the actual PR head and retains its receipt,
input/output corpora, runtime fingerprints and logs. The proof bank documents
the remaining public-ID/parser, serialization/hash, external source authority,
contractual discharge, accounting and regulatory boundaries. This is arithmetic
and asserted-record assurance for the draft; it is not production activation or
closure of issue #299.
