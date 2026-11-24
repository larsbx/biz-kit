# Cross-currency canonical source snapshot: read-only local business history

Date: 2026-11-15. Status: **draft, no accepted production legal or business effects**.

## Relationship to accepted and pending work

- [PR #341](https://github.com/larsbx/biz-kit/pull/341) established a pure exact-rational bilateral cross-currency preview and mathematical correspondence evidence.
- [PR #404](https://github.com/larsbx/biz-kit/pull/404) **merged** the unchanged [PR #399](https://github.com/larsbx/biz-kit/pull/399) Ed25519 consent module plus a **test-only** signed-history and synthetic-grant fixture. #399 was therefore closed as superseded without merging its stale branch.
- [PR #392](https://github.com/larsbx/biz-kit/pull/392) is a separate **same-currency** signed business review admission in progress. It must not be treated as cross-currency posting or discharge.
- [Issue #299](https://github.com/larsbx/biz-kit/issues/299) still tracks source reservation, independent business authority and legacy signed-aggregate bypass for a real, effective discharge.

## New narrow increment

`CoopSubstrate.CrossCurrencySourceSnapshot.snapshot/2` is a **production-code, read-only helper**, using the existing *source-owning local* canonical Log, not a new financial or operational writer. It supports exactly **two** identified, open, original-only, reciprocal obligations denominated in **different** currencies.

It performs an entire current local hash-chain audit; reads the current authoritative Log projection; checks the original signed obligation stream for each source; independently verifies both original event envelopes; compares source ID, original revision, amount, currency, parties, stream ID and original signed-core SHA-256 to its local source-lineage fold; and returns each full recorded-event SHA-256 together with current registered member keys. It rejects missing/closed, assigned and reassigned histories, derived legacy residuals, same-currency pairs, nonreciprocal claims, reused IDs, preexisting source reservations, malformed keys, and changed heads.

The output is designed to supply the **fresh local inputs** of `BarterCore.CrossCurrencyConsent.prepare/5` and `verify/7`. That pure verifier separately requires the signed candidate's own rate, identities, exact reductions and expiry. The local helper does **not** independently authenticate a proposed private rate, invoice's underlying delivery, current corporate agency, independent lawyer/reviewer or favorable non-prohibition assessment.

The helper itself does not import `BarterCore` into the production `CoopSubstrate` dependency graph. The existing umbrella test-only Barter dependency exercises the composition against synthetic signed business-history fixtures.

## Trust and limitations

- **Authenticated local record** means valid admitted signed business-log history under that *local* node's signer/key policy. It does **not** prove external invoice delivery, title, legal enforceability or independent corporate appointment.
- Original signed-core hash and full recorded event hash are distinct. The returned cross-currency consent source hashes are **full-record hashes**, while the original-only lineage check uses the **signed-core hash**.
- The exact pair must be re-read at verification. A successful unchanged-head check is only a *snapshot*, not an atomic source reservation; a later append, rollback or cross-host split is not fenced. There is no independent checkpoint freshness.
- Current key IDs and public keys are obtained from the local fold. The v1 pure consent bytes do **not** bind a cryptographic member-key epoch: rotation away and back to identical key material must not be promoted to production corporate authorization using this module. A future signed admission profile must bind independently validated key/grant epochs and fence revocation at commit.
- The helper does not itself prove that the two businesses have legally authorized agents, that the platform is exempt from licensing, or that contractual setoff is operative. A jurisdiction- and activity-scoped **non-prohibition** conclusion remains an independent gate for an activated effect.
- No signed event type, canonical Log append path, journal, payment instruction, FX dealing, custody, Hawala balance or commercially effective discharge is added. The result explicitly carries `admission: :not_authorized`, `discharge: :none`, `currency_exchange: :none` and `financial_settlement: :none`.

## Exact-head acceptance

The commercial-clearing workflow now includes this helper and its ExUnit tests in the PostgreSQL-backed signed-ledger job. The tests include:

1. Signed original USD/EUR event hashes and current registry keys; independent calculation and successful **inert** two-party consent verification.
2. Identical-valued obligation replacement with a different source ID: old history must fail, new history must have different original full-record digests.
3. Assignment out/back, closed sources, same denomination, malformed and absent sources: fail closed.
4. Key rotation: sources persist, current key changes, and old consent proof is rejected by the verifier.
5. Restart: full-record hash and current key snapshot must reconstruct identically.

All hosted checks must run **on the exact branch head**. The CI result is distinct from a source-backed review and from a legal classification.

## Next milestone

Introduce an independently governed **cross-currency business/agent authority and non-prohibition evidence port**, separate from the synthetic fixture and private same-currency PR #392 methods. Then specify a new versioned **signed cross-currency intent** containing exact original source hashes, both currencies, exact agreed rational rate and its contract terms, and full party signatures. Actual debt-closing admission still requires current scoped authority, atomic source-level reservations, replay/race/restart controls and legacy bypass closure. No extension of `NettingExecuted` or assumption of a shared licensed FX provider.
