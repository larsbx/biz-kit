# Buzz task workspace: first implementation stage

Status: internal transport-neutral boundary; not a deployed Buzz integration.

Buzz supplies the human/member/employee/agent collaboration surface. The
CoopSubstrate ledger remains the sole authority for accepted business changes.
This stage implements the already delivered `inbox -> proposed` command and
scoped task cards. It adds no writer, key registry, outbox, database or dependency.

## Delivered interface

`CoopSubstrate.Buzz.Tasks.propose(signed_envelope, log_server)` forwards only a
native `TaskProposedV1` envelope to `CoopSubstrate.Tasks.propose/2`. The existing
append gate verifies signatures, scoped operator grants, current revocation,
expected version and legal transition against committed state.

A successful result contains `receipt` (event ID/hash, global sequence and task
version) and `notification` (scope, task, accepted state/version and stable
`delivery_id`). It performs no HTTP call, agent execution or notification send.
Errors propagate without generating an accepted notification. Keep and retry
the **same signed envelope**, rather than creating another ID or timestamp.
The existing ledger retry contract returns the original receipt after restart,
and even after a later grant revocation; this acknowledges an existing fact.
A newly submitted request remains subject to current authorization.

The notification is an acceptance receipt at a particular task version, not
an assertion of current status forever. It can be delivered more than once;
a future sender/receiver must deduplicate by `delivery_id` and handle ordering
by ledger watermark. Durable notification delivery is not implemented here.

`CoopSubstrate.Buzz.Tasks.cards(replayed_task_state, {chapter, tenant, project})`
builds deterministic cards in task-ID order, filtering all three scope fields
exactly. Cards expose the task title/state/version, last ledger event ID,
Definition of Done text and definition artifact digest. Empty or wildcard scopes
are refused. The caller must supply a trusted ledger replay and independently
authorize the reader. This pure helper is not a public endpoint; it does not
make arbitrary caller-supplied maps trustworthy. Editing a returned card cannot
change the ledger. Replay performs no external effects.

Employees and members use explicit scoped operator grants for this command.
Cooperative membership is neither required nor inferred by the connector.
Channel membership, reaction approvals and caller-provided verification flags
are not accepted commands. There is no implicit privilege union across roles.

## Definition of Done boundary

Cards display the Definition of Done and definition digest from the signed
baseline. The baseline attests preserved source state; it does not establish
historical approval or certify that the definition's artifact bytes were fetched
and checked. This stage does not parse criteria, collect evidence, grant reviewer
rights or admit task completion. The current task lifecycle is unchanged.

The next ledger stage must bind a structured DoD revision, criterion IDs,
artifact receipts, evidence submission/version, reviewer authority and an exact
review target before accepting completion. A reaction cannot approve changing
criteria or evidence implicitly. Cover SOP/predecessor/readiness/execution
requirements and fence the old task writer before enabling production cutover.

## Transport follow-up

1. Pin a reviewed Buzz commit and define the actual client/relay integration.
2. Authenticate Buzz keys and link them explicitly to platform principals.
   Nostr Schnorr signatures are not native Ed25519 envelope signatures. A
   platform service signature must be identified as service attestation.
3. Define server-owned channel/scope mappings and authorize every read/write.
4. Add durable ledger-derived delivery with cursor recovery and stable IDs;
   test crash after append/before delivery and duplicate/out-of-order messages.
5. Implement task cards/checklists in the chosen Buzz client. This module does
   not imply those UI components already exist upstream.

Do not route business writes through the separate Halaqa/Buzz prototype's
caller-provided `author_signature_valid`, membership or policy flags. That
prototype is not the authentication/admission boundary for this task API.

## TDD and validation

The tests-first commit introduces four PostgreSQL-backed acceptance tests before
implementation. They cover durable receipts, exact signed retries after restart,
invalid signatures and flag/reaction inputs, revoked grants, stale versions,
scoped DoD cards and replay recovery. Existing task tests also cover store failure,
ID conflicts, competing commands and direct append authorization.

Five isolated tests exercise deterministic card ordering, scope separation,
DoD provenance, invalid scopes and rejection of unsigned collaboration inputs.
The tests-only load produced five failures for the absent module; loading the
implementation produced five passes. The isolated run used temporary Elixir
1.14/OTP 25, without replacing cryptography or faking ledger append success.

All changed Elixir files were parsed/formatted; `git diff --check` passed.
The PostgreSQL acceptance tests and umbrella compilation were not run locally:
this environment lacks the project's Elixir 1.19/OTP 27 runtime and database
setup. The Consolidation workflow now explicitly checks the new files' format
and already runs the full common-ledger suite. Its CI result must be checked
before merge. Publication and merge are authorized; the current full-suite
validation result is recorded in [PR #5](https://github.com/larsbx/biz-kit/pull/5).
