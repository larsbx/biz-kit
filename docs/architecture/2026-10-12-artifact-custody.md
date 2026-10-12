# Scoped artifact custody on the common ledger

The existing `CoopSubstrate.Harness.Artifacts` filesystem store is reused.
SpruceGoose's kernel ArtifactStore/ContentID interfaces and deployment byte
verification were inspected; their memory adapter is not durable and their
live Ash receipt tables cannot become the common ledger's authority.
No new database, network transport or business-event store is introduced.

## Admission and retrieval

`ArtifactCustodyRecordedV1` is an operator-signed, chapter/tenant/project-scoped
receipt command carrying an artifact SHA-256 and the existing principal/grant
identity. The serialized Log gate checks current authority, fetches stored
bytes, and recomputes their digest before appending the receipt. Direct append
uses identical checks. `ArtifactCustody.submit/2` returns only after the receipt
is committed, with event ID/hash and global watermark. Receipts do not advance
any task version and can be reused within their exact project scope.

Artifacts remain outside the ledger, as required by the substrate's redaction
contract. The writer exclusively creates the final digest path, syncs its file data, and
never overwrites existing bytes. It creates no temporary alias that could survive
erasure. A concurrent reader may observe an incomplete write and refuses it;
a crash-partial final file fails digest verification and requires explicit erasure
before repair. A crash before receipt persistence leaves at most an unreferenced
artifact at its documented digest path; retrying after persistence returns the
original receipt. Ledger replay reconstructs receipts without accessing files.
Storage must use a persistent volume. File-data sync and verification cover completed writes; filesystem/directory persistence, backups, retention,
and protection against external deletion remain deployment responsibilities.
A receipt attests verification at admission, not indefinite retention.

`ArtifactCustody.get/3` requires an exact receipt scope and rechecks the bytes.
It is an internal API for independently authorized readers, not a public access
control endpoint. A deleted or corrupted artifact makes availability false
without changing the immutable receipt or breaking historical ledger replay.

## Receipt-backed evidence

`TaskEvidenceSubmittedV2` retains V1's evidence digest map and adds a
`custody_receipts` map with exactly the same criterion IDs. Every reference
must identify an admitted receipt in the same chapter/tenant/project, with the
same digest and currently retrievable verified bytes. Gate verification streams
64 KiB chunks, caps each artifact at 8 MiB and each evidence operation at 16 MiB.
Oversized artifacts fail closed; large-blob custody is a later adapter obligation. Receipt admission and
submission can share an atomic ledger batch. The existing operator authority,
exact current definition event and optimistic task version are still required.
The submission event itself supplies immutable submission identity.

V1 canonical bytes and historical replay remain supported; new V1 submissions
are rejected with `custody_receipts_required`. Historical V1 evidence is never
promoted to verified custody. Cards expose the V2 receipt
map, or null for V1. Consumers requiring custody must require V2 receipt bindings
and check availability, rather than treating an accepted V1 review as custody.

Acceptance of a receipt-backed submission additionally rechecks availability.
A reviewer can refuse unavailable evidence. Reviewer authority and independence
by principal and signing key remain enforced. Replacement evidence resets the
current review; late reviews of prior submissions or definitions fail. Historical
submissions, receipts and decisions remain in the ledger unchanged.

Custody verification, present availability, review acceptance and task completion
are separate predicates. Every review leaves the task proposed. Readiness,
execution, SOP and predecessor obligations are not implemented by this change.

## Validation

Tests precede implementation in commit history. New acceptance regressions cover
missing/tampered artifacts, digest mismatch, receipt scope, immutable IDs,
revoked authority, replacement evidence, stale submissions, exact retries,
restart/replay, and unavailable acceptance versus refusal. Storage tests verify
exclusive publication, bounded streaming reads, idempotent writes and refusal to overwrite corruption.
The Consolidation workflow compiles the umbrella, checks changed formatting,
and runs the full Elixir ledger and orchestration suites against PostgreSQL.
