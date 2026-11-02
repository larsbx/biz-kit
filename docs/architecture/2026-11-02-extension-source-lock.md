# ExtensionV1: deterministic source-bound release lock

Date: 2026-11-02. Stage: **portable conformance only; no runtime activation**.

`BizKit.Extension.ReleaseLock` constructs a deterministic lock over an
explicit trusted list of compiled ExtensionV1 modules. Each lock item binds:
the extension ID, contract version, implementation version, exact **full Git
commit SHA supplied by the host**, and SHA-256 fingerprint of the strictly
validated, canonically encoded manifest. Dependencies determine lock order.

This detects same-version manifest drift, wrong or extra source pins, missing
dependencies, duplicate module IDs, version mismatch and unreviewed replacements.
The fingerprint is domain-separated and length-delimited, sorting validated
map keys and top-level unordered descriptor collections. It is a local Elixir
V1 encoder and **not** a cross-language JSON canonicalization standard.

A source SHA is not itself an attestation that BEAM bytecode matches a Git tree:
the trusted release builder must verify checkout, source and artifacts against
the recorded commit, then issue an authenticated, durable deployment approval.
The method accepts caller-supplied pins, so no authorization is inferred from
a matching lock. The existing registry can still change metadata visibility
without a lock; it is not a secure activation endpoint.

## Acceptance

- Independent compilation and tests inside/outside the umbrella.
- Negative fixtures for source pin loss, extra identifiers, forged abbreviated
  source identifiers, manifest drift without version bump, dependency mismatch
  and foreign/unknown compiled-module references.
- Exact PR-head CI checkout; the host helper builds and verifies a lock from
  SchoolOps and Dispatch reference descriptors using that checkout SHA.
- No new writers, grants, processes, student records, financial settlement
  semantics, domain migrations or production traffic changes.

## Next stage (tracked in #225)

The actual deployment host must authenticate its reviewed source and artifact
provenance and **current governance approval** at the mutation boundary before
making an extension executable. The transaction/ledger admission boundary must
independently re-check current scoped command permission; neither a source
lock nor a verified approval is a business grant.

Full runtime lifecycle (supervision, isolation, health, stop/restart, rollback),
Hawala separation and independent external wire compatibility remain open.
