# Online evidence intake → offline scorecard export

Status: implemented preparation form, strict records and offline exporter; **synthetic validation only**.
No geographic scope, product category, merchant cohort, actual demand or economic viability is established.
This extends draft [#310](https://github.com/larsbx/biz-kit/pull/310), follows the pilot proposed in
[#309](https://github.com/larsbx/biz-kit/pull/309), and supports [#308](https://github.com/larsbx/biz-kit/issues/308).
It adds no app database, authoritative event store, checkout, payment writer or live collection endpoint.

## Conduct the whole pilot online

1. **Approve the experiment.** The owner chooses one geographic cluster, one category and the
   participating independent businesses, and records the decision privately. Interviews, participation
   terms and consent are collected through approved private online forms, authenticated portal messages
   or remote calls with consented written follow-up. No visits or in-person interviews are required.
   The proposed 5–10 merchants and approximately 100 qualified requests remain recruitment targets.
2. **Choose the existing private source.** Use the organization's approved authenticated form/CRM or
   source-owned application. Assign current reviewers and merchant-specific access. The source retains
   original online responses, attachments, consent versions, signatures and corrections. Keep business
   identity/agent verification and any authorized contact information there. Contact collection,
   recruitment, production hosting and financial operations need separate owner approval.
3. **Make the online forms short.** Use the field groups below. Provide visible labels, keyboard access,
   mobile layout, clear error text, saved drafts in the source, and an accessible written alternative to
   remote calls. Scope choices come from the approved pilot. Buyer-facing forms must not ask users to
   fill internal provenance keys. The coordinator maps those responses to opaque references afterwards.
4. **Qualify and invite.** A reviewer checks specifications, delivery feasibility, consent and duplicates.
   An independent merchant receives only the approved request projection through a private online
   channel. Request/quote ownership and merchant opt-in stay with their source owners. A draft want
   creates neither a purchase obligation nor authorization to pay.
5. **Collect actual offers and outcomes.** Merchants submit their own quotes and revisions online;
   preserve original versions. Bind buyer acceptance to the exact revision and separately record stock
   and terms revalidation. Only independently verified external provider records establish payment or
   refunds. Merchant/carrier online receipts establish fulfillment, with online buyer confirmation where
   appropriate. Document disagreements, failed deliveries, cancellations, returns and unresolved claims.
6. **Review costs and follow-up.** Each responsible role submits its actual attributable costs and a
   completeness declaration online. Record collection gaps; a blank expense is unknown. Obtain
   explicit zero-cost confirmation where applicable. Schedule online 7-, 30- and 90-day follow-up in the
   source's existing process; do not infer no dispute or no repeat from silence.
7. **Extract and review privately.** Source owners produce point-in-time extracts. A coordinator can use
   [intake.html](intake.html) to prepare each structured record from the approved online source and
   submit it back online for source-owner review/versioning. The page downloads a preparation file;
   it does not submit, authenticate or persist it. Host it only in the approved private workflow after
   approval; it works locally for synthetic rehearsal. No third-party scripts, analytics, browser storage
   or network requests are included. The form is for coordinators and source owners, not buyer intake.
8. **Export offline.** Download approved source extracts, freeze the common observation cutoff, run the
   exporter and existing scorecard. Review the private crosswalk against originals. Publish only a
   separately approved disclosure; small-cohort aggregates can reveal commercial relationships.

A prepared browser file is **not authoritative evidence**. Only its accepted source revision and the
referenced original online material can support the extract. This tooling does not cryptographically
verify identities, consent, signatures, provider responses or completeness assertions. Those reviews
remain with the existing source owners; do not claim otherwise.

## Accessible online form groups

These are deployment specifications for the approved existing source, not activated endpoints.

| Online record | Minimum visible fields | Reviewer/source responsibility |
| --- | --- | --- |
| Buyer want | Approved category and delivery area; model/part or measurable requirements; condition; quantity; needed-by; optional all-in budget and currency; consent to scoped merchant sharing and pilot measurement | Assign random buyer/request keys, specification/condition evidence references; qualify or reject with reason; identify duplicate purchase intent; retain submission and qualification times |
| Merchant participation / remote interview | Business and authorized agent in private identity source; category/capacity; opt-in scope; willingness to quote; proposed fees; liability/refund responsibilities; participation terms | Canonical business identity, participant approval, opt-in/withdrawal times and agreement reference. Interview willingness is not an actual quote or realized revenue |
| Invitation / response | Approved request projection; recipient merchant; invitation; first response including decline; decline reason | One merchant–request pair; reminders reuse it. Merchant branches roll up to one canonical independent business |
| Actual quotation | Exact request; firm vs indicative; item/condition and stock evidence; price, tax, freight, fees, currency; issued/expiry times; quote revision; withdrawal | Responsible merchant owns quote history. Indicative/incompatible offers have `qualified=false`. Corrections preserve the old revision and its effective end |
| Fee terms | Supplying merchant, optional separate servicing store, supplier-funded fee basis, currency, validity, custody/inspection/returns/loss duties | Retain agreed terms and acknowledgments online. Keep promised fees distinct from actual gross fees and actual reversals in order observations |
| Acceptance / fulfillment | Exact quote revision; explicit buyer acceptance; stock/terms confirmation; original promised deadline; provider-confirmed payment; full-delivery evidence or failure/cancellation; return/dispute/refund references | Preserve seller of record and item-specific receipt in the source. A buyer claim, QR code or acceptance alone never establishes payment. Retain pending and unreconciled outcomes |
| Attributable cost review | Role; order or unallocated work; currency; actual expense category, amount or unknown; evidence; complete/incomplete declaration | Count each expense once, including work on unmatched wants. Keep fixed overhead/taxes separate; do not add refunds or fee reversals again as costs |
| Follow-up | Contact/check timestamp, channel, evidence, outstanding questions, complete-through time | Lack of response is incomplete observation, not a negative outcome. Reconciliation requires resolved applicable provider/refund/claims windows |

Consent details, reasons, commercial descriptions, liability terms and contact/agent records remain in
source-owned online records and are reached through private references. They are not copied into the
scorecard. The private provenance manifest retains the exact pseudonymous extract and reference set.

## Record and bundle contract

`intake.synthetic.json` is a complete **invented** replay example, not merchant testimony.
`intake.record-schema.json` describes the preparation form's field types (it is a form descriptor,
not a JSON Schema standard). The exporter enforces exact keys and rejects extra fields. For source
integrations, follow the example plus these rules:

- Every row has `source_id`, `owner_id`, `record_id`, positive `revision`, `captured_at`, nonempty
  `evidence_refs`, and `data`. Keys/references are random local 128-bit lowercase hexadecimal tokens;
  never hash names, contact details or guessable source IDs. Source lookup stays private. Reuse keys
  across snapshots; use one canonical request key for one purchase intent. Distinct repeat purchases
  get distinct keys after human review. The exporter rejects duplicate identities and explicit
  duplicate submissions cannot enter the qualified denominator. It does not guess semantic duplicates.
- The control contains `intake_version: 1`, `dataset` (`synthetic`/`observed`), `pilot`,
  `cohort_started_at`, `as_of` and `coverage`. Pilot includes opaque `id`, `geography`, `category` and
  `approval_ref`. An observed export requires an owner-approved scope/participant decision reference.
  This is an assertion backed by source evidence, not an authorization service.
- Each coverage row binds `source_id`, `owner_id`, `collection`, `from`, `through`, `evidence_ref`.
  Declare **every required source**, including empty streams and all merchant owners. Every one must
  cover the complete cohort interval. The source must extract values **as of this cutoff**, not later
  aggregates. Exporting a declaration from a later extraction is allowed only when it reconstructs
  that point-in-time state. `captured_at` is the source snapshot time, within this observation interval.
- Provide latest source snapshots for requests, participation, invitations, fee terms, orders and costs;
  provide **all issued quote revisions starting at 1**. Other multiple revisions are refused rather
  than merged with last-write-wins. Quote revisions keep source ID, record ID, request and merchant.
  A superseding revision clips the previous revision's withdrawal at the new issue time. An accepted
  order binds `{source_id, record_id, revision}`. Withdrawal/expiry at acceptance invalidates it;
  later withdrawal preserves earlier actionable match evidence.
- Merchant participation and quotations must be in that merchant's declared owner boundary. Source
  coverage must bind the same owner. Independent businesses have unique `business_id` values; branch
  identities cannot inflate independence or repeat cohorts. This boundary check assumes honest source
  declarations; it is not a signed authorization check.
- Requests carry `status` (`unreviewed`, `rejected`, `duplicate`, `qualified`), optional `duplicate_of`,
  and source qualification/consent timestamps. A duplicate must link an admitted canonical request for
  the same buyer. Qualified requests must match the approved scope and have sharing consent at
  qualification. `sharing_revoked_at` ends future sharing and becomes an effective withdrawal while
  retaining the historical qualified request. `measurement_authorized` is the source owner's current
  decision that historical measurement retention is authorized. If false, export refuses pending a
  source-owner retention/redaction decision; it never silently erases a denominator or invents consent.
- `observed_through` on each qualified request/order must reach `as_of`. A recent request/order can
  still have complete observation *to date* while lacking seven/30/90 days of maturity. The scorecard
  reports those incomplete windows. Lost follow-up before cutoff causes export refusal. v1 cannot
  encode individual censoring times: lower the **entire** cutoff and re-extract all amounts/events as
  of it, or extend the scorecard contract before analysis. Never silently drop hard-to-follow rows.
- Quote components sum to `all_in_minor`. Currency must agree with the request and order. This v1
  model supports supplier-funded fees only; nonzero buyer-direct fees and other fee payers are refused.
  Gross order revenue excludes pass-through taxes. Fee agreements describe terms; `orders.fees`
  describes realized gross supplier-paid fees and actual reversals, with `null` for unknown fees.
- Costs use one pool per `(order_id or null, role, currency)`. Each `items` entry has a unique stable
  expense ID, `kind`, nullable `minor`, `incurred_at`, `evidence_ref`. The same expense cannot appear
  in another pool. Review all applicable categories before setting `complete=true`. A complete empty
  pool attests zero; a missing pool, incomplete review or unknown amount exports `null`. Order costs
  must share its currency. Unknown unallocated cost pools are explicitly emitted for every used
  currency/role; omission never implies zero. When no service store exists, its order cost/fee must
  be zero; this does not imply that all unallocated service-store pilot expense is zero.
- Provider-verified refunds have unique IDs and evidence references, and remain separate from costs.
  Full refunds and reversed fees preserve incurred expenses and historical paid/delivered realization.
  Keep failed/cancelled accepted orders in the cohort. `reconciled_at` closes financial observation,
  not unknown expense amounts. The existing scorecard validates timestamp, currency and reversal bounds.

## Reproduce an export

Requires Elixir 1.19 / Erlang OTP 27. No services or credentials are needed.

```sh
elixir tools/merchant_pilot/test.exs
elixir tools/merchant_pilot/cli.exs export \
  tools/merchant_pilot/intake.synthetic.json /tmp/merchant-synthetic-export
elixir tools/merchant_pilot/cli.exs score \
  /tmp/merchant-synthetic-export/snapshot.json
```

For separate source-owned record extracts, put approved files in a private directory. Each JSON file is
`{"collection":"requests", "record":{...source envelope...}}`, matching the preparation form download.
Maintain an export control JSON with the six control keys listed above, without collection arrays:

```sh
elixir tools/merchant_pilot/cli.exs export \
  /private/pilot/control.json /private/pilot/reports/cohort-001 \
  --records /private/pilot/approved-source-extracts
elixir tools/merchant_pilot/cli.exs score \
  /private/pilot/reports/cohort-001/snapshot.json > /private/pilot/cohort-001-report.json
```

The output directory must be new. It contains `snapshot.json` (unchanged scorecard v1 contract) and
`provenance.private.json` (source extracts, exclusions, revision mapping, coverage, scope and canonical
snapshot SHA-256). The CLI creates owner-only files/directories on POSIX, refuses overwrites, removes
partial writes on ordinary failure, and never prints source rows or filenames in error messages.
On Windows use an access-controlled private directory: POSIX mode bits do not establish Windows ACLs.
Treat both outputs and source extracts as private even though identifiers are pseudonymous. The
manifest is an audit crosswalk, not a ledger, tamper-proof signature or cryptographic evidence of truth.

The synthetic replay independently checks match **1/2**, with one early withdrawal and one incomplete
request; one finalized on-time order and one pending order; one mature dispute cohort. The finalized
order has supplier revenue **8,300**, supplier contribution **1,300**, service-store contribution **20**
and platform contribution **300**, all USD minor units. Unknown pending order inputs withhold complete
supplier/platform cohort margins. Store contribution after its unallocated cost is **10**. These are
fixture arithmetic, not observed economics.

## Before approved online collection

- Owner records geographic/category/participant approval, applicable source access, retention and
  disclosure decisions; source owners review merchant/agent identity, consent and operating terms.
- The chosen online source supports access controls, audit/version history, safe file retention and
  per-merchant isolation. Rehearse source upload/review/extraction and buyer accessibility there;
  this standalone form cannot establish those host properties.
- An operator reviews one complete synthetic source-to-report replay and adversarial failures. Real
  records never go to GitHub, CI, fixtures or public hosting. Do not promote `synthetic` to `observed`.
- Pilot review considers cost completeness, cohort maturity, selection bias, baseline alternatives and
  per-business losses. No automatic success/keep/pivot/stop decision or advanced feature activation occurs.

The scoped workflow also runs `test_intake_form.cjs` with Playwright 1.62.1/Chromium: it fills all
seven record types from the synthetic fixture, checks exact downloaded records, native field validity,
mobile/desktop overflow, browser errors and absence of remote requests. Run it with Playwright installed
in your test environment (`node tools/merchant_pilot/test_intake_form.cjs`). These browser checks do
not establish accessibility or privacy of the eventual authenticated online host; rehearse that host
separately with its actual access and retention controls.

[Formal coverage](formal/README.md) specifies qualification, observation windows, quote revision
binding, unknown evidence, refunds and role margins in Lean and Quint. Its server runners include
actual-exporter conformance examples and mutation witnesses. It is not an end-to-end proof of the
Elixir implementation, source authenticity or actual commercial evidence.
