# Merchant procurement pilot scorecard

This offline reader implements the measurement definitions in [draft PR #309](https://github.com/larsbx/biz-kit/pull/309) and [issue #308](https://github.com/larsbx/biz-kit/issues/308) for one metro and one product category. Run it from the repository root with Python 3.11+ and the standard library.

```sh
python3 tools/merchant_pilot/scorecard.py tools/merchant_pilot/synthetic.json
python3 -m unittest discover -s tools/merchant_pilot -v
```

The fixture is entirely synthetic. The report labels its source as `synthetic` or `observed` and reports exact numerator and denominator counts. A zero denominator means the rate is undefined. Apply the proposed gates only after reviewing sample size, censoring, selection bias, and the completeness of costs and follow-up. The calculator emits measurements and coverage, without an automatic pilot verdict.

## Prepare a private snapshot

Use the fixture as the strict v1 JSON schema. Keep an immutable snapshot per report with its `cohort_started_at` and `as_of` in UTC to whole seconds. Export all in-scope events from cohort start through the cutoff, inclusive. Keep known future deadlines as timestamps and unobserved events as `null`. This assumes sources are complete through the cutoff, so advance it only as far as the least current required source. Generate a new snapshot after late evidence or corrections. Keep the source revision and evidence crosswalk privately with the export.

| Rows | Source and export rules |
| --- | --- |
| `requests` | Include requests that met the documented qualification and consent rules. Exclude rejected or duplicate submissions. Preserve an observed subsequent withdrawal. |
| `invitations` | One row per invited merchant and request, with the first response time including explicit declines. Count revisions or reminders under the original invitation. |
| `quotes` | Use one opaque ID per immutable source revision. Map the merchant-scoped catalog quote and checkout pricing to a comparable landed total and an ISO currency. Source owners attest the quote was firm, item-compatible and actionable by setting `qualified`. Capture expiry, withdrawal and supersession as effective times. Record a superseded version's end as its withdrawal time if that is earlier than its expiry. |
| `orders` | Link the exact accepted quote version after stock and terms revalidation. Use the seller's original promised deadline and evidenced full delivery, cancellation or failure. Record the first actual return and first dispute requiring human intervention separately. A retry uses a fresh quote revision and follows a recorded cancellation or failure. Use externally confirmed payment and refund records, with unique refund IDs. |
| `unallocated_costs` | Include incremental costs that were never allocated to orders, such as time spent on unmatched requests or unsuccessful quotes. Provide at most one entry per role and currency. Omission attests no unallocated cost for that role and currency. Use `null` when the amount is unknown. |

[CommerceCore.Catalog](../../apps/commerce_core/lib/commerce_core/catalog.ex) supplies merchant-scoped quotes and [CommerceCore.Pricing](../../apps/commerce_core/lib/commerce_core/pricing.ex) supplies currency-checked priced snapshots. The export preserves their single-currency convention and reads evidenced outcomes separately. [CommerceCore.Checkout](../../apps/commerce_core/lib/commerce_core/checkout.ex) creates candidates whose financial status is unconfirmed. Export `paid_at` only from independently verified provider evidence. This tool runs on the resulting file with no app, provider or ledger connection.

Use random local 128-bit lowercase hexadecimal tokens for IDs, stable across snapshots of this pilot. Keep contact details, business names, source identifiers, item descriptions, authorization records, and provider references in their source systems. The parser rejects extra fields and reports errors without printing row contents. The default report omits row IDs. Use `--include-orders` for private review of pseudonymous per-order margins. Even aggregate outputs from a small cohort can reveal transaction economics, so keep both outputs private and review disclosures before sharing.

## Measurement rules

| Measure | Calculation |
| --- | --- |
| Seven-day match and latency | Start at qualification. Use requests observed for seven full days, reporting early withdrawals and incomplete windows separately. Count a quote that was actionable when issued through the day-seven boundary, even if it was later withdrawn. A quote withdrawn at issuance never qualifies. Median latency uses only matched requests in the mature cohort. Report unmatched mature requests separately. |
| Merchant response and acceptance | Response rate uses invited merchant–request pairs in mature cohorts, counting responses through the same seven-day boundary. The funnel also reports distinct requests with an accepted order and the number of accepted orders through the snapshot cutoff. |
| Fulfillment, cancellation and returns | The final-outcome denominator includes on-time and late deliveries, failures and cancellations. Pending orders are reported separately, with a count past their promise. Returns use delivered orders as the denominator and refunds use all accepted orders. Both are to-date measures. |
| Intervention disputes | Start at acceptance. Only orders with full 30-day follow-up enter the denominator. A qualifying dispute at the 30-day boundary counts. |
| Merchant repeat | Realization occurs at the later of confirmed payment and evidenced full delivery. Returns and refunds change economics while preserving the historical paid-and-delivered event. Count a second realized order through day 90 after the first in the pilot. Report merchants whose first realized order lacks 90-day follow-up separately. |

The draft's experimental thresholds are at least 30% matching, median first offer under 72 hours, at least 90% on-time fulfillment, under 3% intervention disputes and at least 40% merchant repeat. Volume, competitiveness, merchant selection and whether losses concentrate in particular businesses still require pilot review.

## Contribution and sensitivity

Every monetary amount in an order, including refunds, fee reversals and incremental expenses, uses integer minor units of the quote/order currency. Verify this with source currency metadata before projection. The reader checks that the order and quote currencies agree and reports separate buckets per currency. It performs no currency conversion.

- **Supplying merchant** takes confirmed gross sales excluding pass-through taxes, less buyer refunds and net fees payable to the servicing store and platform, less its own incremental expenses.
- **Servicing store** and **platform** each take their respective merchant-paid fee less any reversal and their own incremental expenses. Export fees gross of reversals. Where no separate servicing store participated, use zero store fees and costs. This v1 fee model covers supplier-funded fees. Buyer-direct or third-party fee arrangements require an extension before those orders can be analyzed.
- Export incremental costs once to the role that bears them. Include applicable acquisition, processing, inspection, storage, handling, shipping, fraud and chargebacks, return losses, support, variable operations, customer acquisition and insurance. Buyer refunds and fee reversals already represented in their own fields stay out of costs. Use zero only for confirmed zero and `null` for unknown amounts. Fixed overhead, capital cost, and taxes remitted are outside contribution.

Include accepted but cancelled, failed or returned orders so their attributable losses remain visible. Set `reconciled_at` only when the financial observation is closed for the snapshot, with provider outcomes and applicable refund and claims windows resolved. Reconciliation can coexist with missing cost inputs. The report identifies unreconciled and missing-input rows separately, shows known-order subtotals with coverage, and withholds the full role/currency cohort margin if any input or reconciliation is missing.

The baseline and 10% and 25% cost increases hold revenues, fee terms and observed refunds constant. Additional cost rounds up to a minor unit per order and per unallocated cost pool. Each scenario reports losses and break-even-or-worse counts, so positive pooled margin cannot conceal their occurrence. Optional order detail gives signed cost headroom. Positive headroom is the exact additional cost that would exhaust contribution, zero is break-even, and negative headroom is the current shortfall.

The scorecard has no transaction, payment, custody, settlement, auction or barter execution surface.
