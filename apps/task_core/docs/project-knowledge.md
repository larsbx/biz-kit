# Project knowledge from accepted operational facts

`TaskCore.Knowledge` derives reviewable knowledge from the current replay state.
Opening a project does not create a draft event: eligible sources appear in a
deterministic pending projection. Governance approves, rejects or withdraws the
exact generated snapshot through the existing signed append boundary.

## Sources and scope

Version 1 derives two kinds of candidate:

- A completed task whose current submission has an accepting review, matching
  completion, and custody receipt references for its evidence. The source pins
  include the lifecycle version, actual completion event, definition, submission,
  review, evidence digests and receipt IDs. The draft contains retained task text
  and completion criteria; evidence bodies are never copied or interpreted.
- A workflow under its current adopted blueprint revision. The source pins
  include the adoption event, repository, commit, tree, path, manifest digest and
  workflow digest. If present, its resolved readiness contract includes the SOP
  and input digests, including the adopted manifest. The draft describes the
  template; it does not claim that its work was completed.

Each candidate belongs to one exact chapter/tenant/project. The pure API does
not authenticate readers. Its host must authorize that project before calling
it and recheck current access before releasing a response. Existing shared
reference-catalog access through any Operations workspace is insufficient for
project-derived knowledge. Evidence remains behind its existing custody access
rules; a feed/suggester grant does not gain evidence-body access here.

The stable ID binds the scope, source kind and task ID or roadmap/workflow keys.
The source fingerprint binds the substantive source revision separately.
`TaskCompletedV1` is found in retained accepted commands: `task.last_event_id`
can change after completion when timing is revised. Scheduling and todo data
are excluded from this generator, so timing changes do not regenerate knowledge.

## Read API

All read values have string keys. Every digest, including nested source pins,
is lowercase hexadecimal. The functions are:

```elixir
Knowledge.candidates(state, scope) # stable-ID-ordered list; no artifact reads
Knowledge.candidate(state, scope, id) # {:ok, candidate} or {:error, reason}
Knowledge.counts(state, scope) # pending/approved/rejected/withdrawn/stale counts
Knowledge.verify_availability(state, candidate) # :ok or {:error, reason}
Knowledge.approved(state, scope) # current approved candidates with available sources
```

A candidate carries `id`, `generator_version` (1), `kind`, `title`, `summary`,
`body`, `source`, `source_fingerprint`, `draft_digest`, `review_version`,
`status`, `current` and `review`. The exact snapshot consists of the six fields
`generator_version`, `kind`, `title`, `summary`, `body`, and `source`; the ID is
separate. Text is plain data, bounded to 300 bytes for the
title, 600 for the summary, and 16 KiB for the body. Long bodies have an explicit
excerpt marker; the source fingerprint still binds the complete source facts.

Counts express decisions and source currentness, without filesystem checks.
An approved item whose bytes disappear remains historically approved, while
`approved/2` excludes it. Hosts may rank current approved metadata first and
call `verify_availability/2` for a bounded set of prospective suggestions.

`review` retains the latest decision's event ID, governance key ID, reason,
version, fingerprints and exact snapshot. A current source with no matching
review is pending. The same rejected or withdrawn fingerprint stays suppressed
across reads and replay. A changed substantive source becomes pending under
the same stable ID; the old approval does not cover it. A retained approval
whose source is no longer eligible is displayed as stale, never suggested.

## Signed review contract

The only new event is `KnowledgeCandidateReviewedV1`. Its project-scoped
payload has exactly these fields:

```text
tenant_id, project_id, candidate_id, expected_review_version,
generator_version, source_fingerprint, draft_digest, snapshot,
decision, reason
```

The event's two top-level digests are protocol `{:bytes, <<32 bytes>>}` values;
the snapshot's nested source digests remain ordinary hex strings. Decision is
`approve`, `reject` or `withdraw`. The stream is scoped to the project and stable
candidate ID; review versions advance independently of task versions.

`review_payload/5` builds the payload for a current candidate and reason. The
host must compare the reader's displayed fingerprints, snapshot and review
version before holding it for a signature. At actual admission, the core again
checks a current declared governance key, expected review version, complete
snapshot and exact source/draft pins. A generic signed event cannot bypass
these checks. Unrecognized fields and malformed values are refused.

Approve/reject applies to pending candidates. A current rejected or withdrawn
candidate may be explicitly approved again using its new review version and
exact pins. Duplicate decisions in the same state are refused. Withdrawal
selects the retained approved snapshot, even when the source is missing or a
new source is pending. That historical snapshot is what the signer must see.
Withdrawing an old revision does not reject a newly pending source revision.

Approval verifies availability through `TaskCore.Host.verify_artifact/2`:
completed-task evidence must have matching scoped receipts and intact bytes
(8 MiB per artifact, 16 MiB total); workflow-summary source is its retained
manifest (1 MiB). A workflow's separately referenced SOP and execution inputs
remain governed by existing readiness/custody rules. Rejection and withdrawal
do not require available source bytes. Missing bytes cannot block withdrawal
or erase a historical decision.

Replay retains the exact signed snapshot and decision without artifact reads,
generation effects, or publication. New generator semantics require a new
version; old approved text must not be rewritten during replay.

## Boundaries and verification

Approval makes this generated reference available within its project. It does
not change task state, adopt a new blueprint, approve a different SOP, publish
to Git or another audience, or execute a procedure. The source log and existing
artifact store retain their ownership. This adds no worker or independent
knowledge business ledger.

`test/knowledge_test.exs` covers automatic population from an admitted workflow
and completed task, source/provenance checks, timing stability, exact approval,
rejection/withdrawal and explicit reconsideration, source changes, payload
substitution, version races, scope/signers/revocation, missing/tampered bytes,
receipt scope and replay without reads. These pure tests assume the host has
verified signatures; real cryptographic and HTTP checks belong to host
acceptance. The existing Quint lifecycle abstraction does not model this
knowledge review contract.
