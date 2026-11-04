# SchoolOps private practice session contract v1

**Proposal only.** Refs [#300](https://github.com/larsbx/biz-kit/issues/300)
and [SchoolOps #37](https://github.com/larsbx/school-ops/pull/37). The
[executable synthetic model](private_practice_contract_test.py) runs with
`python3 docs/contracts/school-ops/private_practice_contract_test.py -v`
from the repository root. It models the required ordering and refusals using
fixtures. Production adapter conformance remains an acceptance gate.

## Existing authority

- [Identity](../../architecture/2026-10-18-identity.md) authenticates and
  resolves the stable principal. A read session supplies identity only. Begin
  requires a signed command from the principal's authorized device key.
- [CoopSubstrate.Log](../../../apps/coop_substrate/lib/coop_substrate/log.ex)
  serializes signed admission. Its `append_if/3` can check the current gate
  inside the append operation. A prior `gate/1` snapshot alone cannot fence
  a revocation. `replay/2` folds history for state and never runs generation.
- [SchoolOps architecture](../../architecture/2026-10-23-school-ops.md)
  assigns tasks to TaskCore and the common ledger. Workflow planning and the
  Grade 2 public catalog grant no authority. Where a shared assignment
  already exists, bind its ID and verify scope against that authority.
- The [storage ADR](../../architecture/2026-10-30-postgres-event-log-redis-consolidation.md)
  identifies the active PostgreSQL-backed EventStore and a gated replacement.
  Protected PostgreSQL storage owns the bytes and operational receipts.
  Use the existing signed ledger for business admission. Redis may wake
  workers. The private session record has no task transition authority.

## Command and response

| Command | Strict v1 body | Authority and result |
| --- | --- | --- |
| BeginPracticeSession | command version, assignment ID, idempotency key, approved source pin ID | Signed write. Current learner-self grant for this assignment. Returns an opaque handle and the committed learner bytes, or a retryable pending result. |
| ResumePracticeSession | command version, opaque handle | Authenticated read. Current learner-self grant for the stored assignment and same owner. Returns the same committed learner bytes. |

Resolve home, organization, class, assignment and learner owner through shared
authority. A tenant selection is a lookup hint. Accept no caller principal,
role, seed, storage locator, or generator version override. Validate exact
field sets and types, bounded identifiers and payload sizes before work. Use
a cryptographically random handle of at least 128 bits. Teacher access uses a
separate authenticated custody read with explicit current teacher-key capability
for the stored scope. Class membership, learner-self access and administrative
titles convey no teacher-key permission. Use a uniform unavailable response
for missing and inaccessible records. Malformed and unsupported inputs fail
closed. Release checks must have a defined ordering with revocation and
session expiry. A completed revocation must deny subsequent access, including
retry and access through cached results. Prove the release fence against the
actual authority. Already delivered bytes cannot be recalled.

## Source and immutable custody

Resolve the approved pin server-side to the authoring repository, exact commit,
Cargo.lock SHA-256, build target/toolchain, binary SHA-256, approved content
SHA-256 and review record. Distinguish contract version 1 from generator
`(schema=2, version=g3-is-source-metadata-rust-v2)`. Require the exact pair
and an approved reader for the stored pin. Archive Python-v1 through an
explicit segregated version-aware reader with its own access checks.
Unknown, malformed, or mismatched pairs are refused without fallback.

Commit SHA-256 of exact learner bytes and a domain-separated binding over
the canonical immutable scope, owner, assignment, handle, source pin,
generator pair and learner digest. Production must specify a canonical
encoding and test cross-language vectors. Bind the separate teacher bytes
and original manifest (which contains the nonce, classifications and answer
digests) through authenticated encryption with the same immutable context
and a purpose tag for each payload. Verify these objects against trusted
admission/receipt bindings, rather than hashes supplied by a saved file.
Resume serves original stored bytes. The upstream Rust verifier reconstructs
a candidate for verification, so any use belongs inside restricted custody
and can never replace a saved form. Quarantine inconsistent or missing
objects. Never repair by drawing fresh randomness under the same handle.

Use tenant-scoped encryption keys under approved platform custody. Protect
learner bytes too. Scope storage lookups by tenant and handle, then enforce
class, assignment, owner or staff capability. Use a private execution
directory or equivalent isolated boundary, bounded output, and no exported
generator stdout or errors containing material. Keep forms, names, nonce,
answer digests, manifest, raw request identifiers and decryptable pointers
out of public catalog, task text, logs, caches, Redis and permanent ledger
events. The signed ledger carries an opaque operation reference and, where
necessary, a privacy-reviewed hiding commitment. Use protected receipt data
to resolve the reference. Agree retention, deletion, key rotation, backup
expiry and audit access before activation. Keep replay-safe tombstones through
the accepted retry horizon and never resurrect expired material.

## Begin, crash recovery and replay

1. Canonicalize the signed request. Permanently bind the operation ID to
   the home, organization, class, assignment, principal, command version
   and idempotency key. Bind its normalized request and resolved source pin
   to that ID. Same key and changed body is a conflict. Use shared admission
   to accept an intent before generation, with current grants and stable
   signed event identity. Recovery of an ambiguous append must reconcile
   against the canonical log before retrying.
2. The authorized worker rechecks authority and the pin. Privately stage
   the complete encrypted form/key/manifest bundle using an insert-once
   operation identity. Generation can run again after a crash before a
   candidate is durable. Only one complete candidate may become durable
   for the operation, and a durable candidate is never replaced. Recheck
   at signed completion admission against revocation and the exact candidate
   binding. The worker acts with its own narrowly scoped service authority
   linked to the admitted user intent.
3. The private session becomes visible only after matching signed completion
   and a durable custody receipt. With separate transactions, stage first,
   append once using a stable outcome ID, then finalize receipt and cursor
   together. Crash after append reconciles the same candidate and outcome
   before advancing. An orphan stage is inaccessible, with governed cleanup
   that first proves there is no accepted completion. Replies and worker ACKs
   require durable completion. Recheck current authority before a reply,
   including duplicate Begin.
4. Consume a verified bounded complete prefix, refusing gaps and unknown
   event types. Replay rebuilds operational state from accepted IDs and
   receipts and never generates forms. Redis loss cannot erase these bindings.

## Proof and release conditions

- **Authority refinement.** Name the reviewed real capability/scope mapping,
  signer and event types, and prove all releases enforce current grant and
  session validity. Race revocation, role changes and session expiry against
  intent, completion, duplicate Begin and both read paths.
- **Single publication.** On the active backend, run concurrent same-key and
  conflicting requests across workers. Kill before staging, after staging,
  after signed completion and before response. Show one visible form and
  outcome, no cursor skip, and correct recovery after Redis loss. Demonstrate
  that private bytes are immutable and receipts match signed authority.
- **Confidentiality and integrity.** Exercise tenant/class/owner and teacher
  capability isolation through real endpoints and storage roles. Mutate or
  replace form, manifest, custody binding and version metadata. Verify
  redaction in responses, audit, logs, tracing, backups and effect receipts.
  Exercise retired pins and archive dispatch.
- **Source acceptance.** The inspected revision
  `345d033dfa2232bef09d3b5008fed8f743975891` is a candidate only. The
  [Rust workflow failed](https://github.com/larsbx/school-ops/actions/runs/41689728115)
  and the crate lockfile was absent at that path. Require reviewed lockfile,
  exact-head locked builds, tests, format, clippy and CLI negative checks on
  Linux, Windows and macOS before pin approval.
- **Educational and release acceptance.** Require owner approval of exact
  source and authority model, independent security/privacy review, qualified
  scholarly/source and age-suitability review, and curriculum readiness
  approval. The pilot uses fictional records and text-free locators. It
  establishes no mastery, worship or belief assessment, or source
  authentication. This proposal wires no runtime and registers no course.
