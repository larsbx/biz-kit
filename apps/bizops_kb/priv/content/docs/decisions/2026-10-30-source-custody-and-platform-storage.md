# Knowledge source custody and disposable retrieval indexes

Date: 2026-10-30 (America/Chicago).
Status: **Selected integration target; implementation and cutover gated.**

Shared contract: [biz-kit storage/consolidation ADR](https://github.com/larsbx/biz-kit/blob/adf9d7d7e03e80af650124ce0fdfd02a232cb9b3/docs/architecture/2026-10-30-postgres-event-log-redis-consolidation.md)
([PR #207](https://github.com/larsbx/biz-kit/pull/207)); financial boundary:
[hawala-core ADR 0007](https://github.com/larsbx/hawala-core/pull/57).
These records specify design, not runtime acceptance.

## Context

The README makes this vault the editable source and names SpruceGoose/Systemwide SOP for operational admission/promotion/distribution. That authority remains until verified succession; a search index is not its replacement.

## Decision

- Git keeps editable source bytes, attribution, paths, rights and exact revisions.
  Preserve Johnny.Decimal structure and stable references. SQL/Redis imports do
  not become authorship or authorize an SOP.
- PostgreSQL may retain approved manifests, provenance, review/admission evidence
  and projections. A source commit or embedding alone does not approve publication.
- Redis may hold scoped retrieval/search indexes, metadata caches and indexing
  delivery. Key by source revision, visibility and installation scope; verify
  approved source before using a search result to act.
- Rebuild from retained source plus governed publication records. Cache loss
  cannot promote drafts or silently substitute latest. Recheck current access
  and withdrawal; stale search results cannot preserve withdrawn permission.
- Keep restricted SOP/artifact bodies and credentials out of public caches and
  stream payloads. Retrieval and execution remain separately authorized.
- Migrate promotion/distribution consumers with original receipt IDs before
  retiring SpruceGoose; platform installation itself creates no authority.
- A financial procedure being indexed cannot authorize payment. TB is not a
  document store or knowledge authority.

## Acceptance and rollout

- Delete/rebuild Redis and compare source hashes, IDs, publication status and
  access decisions.
- Withdraw document/access and reject stale-cache action; inspect public output
  for restricted-source leakage.
- Duplicate indexing/publication work without duplicate promotion/distribution.
- Verify successor admission and old command fencing before authority transfer.

Keep current permissions, services and durable owners until verified replacement,
recovery and single-writer cutover. Recorded historical acceptance does not certify
new adapters. A documentation merge alone moves no live authority.

## Source contracts

[Source authority and provenance](../../README.md).
