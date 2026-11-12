# Research exchange integration acceptance

Prepared November 12, 2026. This change integrates the already-verified closure
core and the bounded MCP admission adapter on a branch from current main.
Implementation review and approval remain separate from execution evidence.

## Exact selected source

PR #336 was merged into the #335 feature branch after #335 reached main. This
integration brings its source onto the main-derived branch without modifying
the core package, its proofs, toolchain lock or source manifest.

| Identity | Value |
| --- | --- |
| Core source revision | `d6c07ef7b57e844c3aaad8d2c7dff938098a71bf` |
| Core source manifest SHA-256 | `e46f8f6c12f790d6889085d072b58f92067004077a8b7f430abcb8433bbb0776` |
| Source inventory | 64 files |
| Registered core properties | 76, including 13 closure properties |
| Required core plan | All 12 stages, in order, with none skipped |

The chosen identity lives in
[`CORE_SNAPSHOT.json`](../../../proof_bank/research_exchange_mcp/CORE_SNAPSHOT.json).
The MCP server embeds that file at compilation and returns it in discovery and
receipt bindings. Both CI workflows read the same record. The identity checker
requires the named Git revision's manifest, the selected SHA-256 and the complete
current source inventory to agree. CI requires a clean exchange source tree and
records the actual checked-out commit/tree and workflow revision separately.

The historical source revision identifies the selected core content. It is not
the current adapter commit or evidence that an MCP request ran a proof checker.

## Implemented acceptance coverage

The existing closure core preserves admitted candidate history, refunds the
original fixture escrow exactly once after a definitive profile rejection,
and leaves unavailable/inconclusive checking inert. Its proof and runtime
acceptance gates retain authority/epoch/version checks, competing decisions,
crash-before/after-commit controls, seven Lean negatives and complete bounded
Quint exploration.

The MCP acceptance suite now sends actual newline-delimited JSON-RPC to a child
process through `initialize`, `notifications/initialized`, `tools/list`,
`library_discover`, `proof_submit`, `verification_request` and `receipt_get`.
It carries returned submission and job IDs into later requests. It checks the
reviewed core identity, full binding, receipt MAC, inert authority flags, exact
retries, conflicting key reuse, duplicate reservation refusal and both stored
receipts. Request IDs are distinct and responses are correlated.

A separate test passes serialized messages through the wire decoder with two
authenticated sessions sharing one server. It checks access to an existing
other-principal submission and job. This is shared-state authorization coverage;
the single-credential stdio launcher does not switch identities dynamically.

The core identity checker has independent refusal controls for stale manifest
pins, a historical Git manifest mismatch, changed/extra source, duplicate JSON
keys and malformed revision/digest fields. A source-manifest creation command is
never part of acceptance.

## Reproduction and evidence

Follow the [MCP commands](../../../proof_bank/research_exchange_mcp/README.md) on
Elixir 1.19.0 / OTP 27.3.4. The identity check needs the chosen Git revision;
the documented exact-revision fetch supplies it. Run the [complete core
profile](../../../proof_bank/research_exchange/README.md) using the digest in
the shared record and the unchanged locked Lean/Quint/JRE distributions.

Acceptance requires both dedicated workflows at the same proposed integration
head. Their path scopes include both packages and either workflow. The core
workflow retains its Git provenance, proof exports, model and runtime observations
and full 12-stage receipt. The MCP workflow retains before/after source identity
records and its executable test log. An earlier component pass cannot replace
these integration-revision records. Queued, failed and skipped runs remain
distinct from acceptance.

## Remaining proof and runtime boundary

This milestone integrates sources, evidence identity and transport acceptance.
The MCP adapter remains memory-only; the HTTP/SQLite pilot remains a separate
local runtime using fixed reviewed exports and disposable fixture credits.
MCP receipts retain `mathematical_acceptance: false` and `credit_issuance: false`.
There is no new public endpoint, UTCP manual, library materializer, general
Lean/mathlib/Quint executor, physical meter or credit policy.

The next proof must define a concrete representation relation from MCP admission
and persisted records to the selected Lean state. Its successful committed step
must preserve the exact candidate/target/environment/policy and current authority
epoch, and correspond to the permitted formal transition. Refusals and
inconclusive observations must preserve represented state. Storage atomicity,
checker truth and cryptographic identity remain explicit premises wherever they
have not been independently discharged.

The next runtime acceptance should carry one MCP candidate through durable
admission, actual dual-checker replay and a terminal result, then exercise
wrong-target, substituted-source, revoked-grant, competing-delivery and
crash/retry cases. That bridge and any deployment or issuance require their own
implementation and approval decisions.
