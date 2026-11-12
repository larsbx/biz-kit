# Durable MCP bridge — proof and acceptance contract

This follow-up to PR #377 connects the existing four-tool MCP stdio interface to
a local SQLite store, the existing controlled export checker and the bounded
Lean source profile. Selection is
explicit in operator-owned configuration. The memory backend remains the default.
This document describes the implemented contract and required acceptance gates;
hosted execution evidence and implementation approval remain separate records.

The existing [disposable replay pilot](../../../proof_bank/research_exchange_mcp/durable/README.md)
remains available through its `durable_database` and `receipt_key_base64`
configuration. Its offline replay records observations with both authority flags
false. This bridge is selected by the separate exact configuration
`backend: "durable"`, `bridge_config`, and `python_executable`; it retains the
guarded acceptance contract below. Mixed configuration fields are refused, and
the two database formats and receipt semantics are not migrated or combined.

## Selected foundation and new source

The core remains byte-identical to revision
`d6c07ef7b57e844c3aaad8d2c7dff938098a71bf`, manifest
`e46f8f6c12f790d6889085d072b58f92067004077a8b7f430abcb8433bbb0776`.
The authoritative value is the shared
[`CORE_SNAPSHOT.json`](../../../proof_bank/research_exchange_mcp/CORE_SNAPSHOT.json).
The new package is
[`proof_bank/research_exchange_bridge`](../../../proof_bank/research_exchange_bridge/README.md).
It imports the existing Lean closure semantics and Python reward transitions;
it does not modify their source, proof registry or toolchain pins.

## Concrete representation

The admitted binding contains contributor, library, engine, source revision,
source snapshot digest, generation, target, artifact digest, environment digest,
policy digest, core revision and core manifest digest. All twelve fields survive
the projection into the core candidate. The new Lean encoding uses UTF-8 bytes
and an out-of-byte-range tuple delimiter, with proved injectivity; it does not
assume that a lossy text encoding preserves distinct records.

The formal row includes immutable binding, submitted/accepted/rejected phase,
version, requester/verifier enablement and epochs, and the core's disposable
fixture arithmetic and terminal-effect fields. The runtime constructs the
authority fields by joining the current grant and verifier records in the
committing transaction. Cached job authority fields are not current authority.

The independent Lean row transition checks complete binding equality, the exact
controlled profile, current requester/verifier identities and epochs, the row
version, a definitive checked outcome, and the submitted fixture state. It
implements accepted/rejected arithmetic directly. The representation theorem
then shows that projecting the result equals the existing `Closure.decide`
transition when the guard holds. Refused calls and inconclusive results stutter:
they leave the represented state unchanged. The statement does not assert
reverse equivalence for arbitrary corrupt rows.

Forty fixed theorem targets cover encoding, complete binding preservation,
correspondence, conservation, terminal inertia, retries and individual guards.
Six additional source-boundary contracts cover evidence identity, replay of the
same closure, prohibited axioms, missing evidence, and refused or stale evidence
stuttering. These make 46 required targets. The source contracts are conditional
statements about abstract evidence; they do not prove Python materialization,
compiler correctness or the association of hashes with actual bytes.
An independently elaborated contract fixes each registered statement. Acceptance
requires a cold build from copied source, the approved axiom policy, exported
dependency replay by both the Lean kernel and lean4lean, and controls for omitted
targets, substituted targets, invalid propositions, unapproved axioms, `sorry`,
and a weakened proposition that still compiles.

## Runtime lifecycle

| Operation | Durable behavior |
| --- | --- |
| `library_discover` | Returns authorized, operator-provisioned library metadata. Execution is described as `durable-operator-provisioned-profiles`; the installed library and receipt identify the particular profile. |
| `proof_submit` | Validates the target/catalog/source fields and artifact digest, then stores immutable bytes, a bound receipt and permanent principal/request identity atomically. |
| `verification_request` | Revalidates the grant and library; creates one job and pending dispatch record in the same transaction; returns promptly with a queued receipt. |
| Controlled worker | Loads a snapshot and checks its installed profile outside the transaction, then revalidates current identity, epochs, binding, bytes, profile and version before committing. The normal background worker handles reviewed exports. Source checking requires an explicit operator-selected job and import bundle. |
| Terminal commit | Calls the existing reference transition and atomically writes the state, one fixture effect, terminal receipt and completed dispatch record. |
| `receipt_get` | Returns the latest receipt only to the currently authorized owner. Exact write retries retain their original request receipts. |

The accepted receipt sets `mathematical_acceptance: true` only after actual
controlled dual replay and a successful guarded commit. Its explicit scope is
`exact-reviewed-export-only` for the reviewed export or `bounded-lean-source-v1`
for the restricted source library. Source acceptance also requires compilation
against the fixed statement, the axiom audit, and dual replay of the same exported
closure. Admission, rejection and inconclusive receipts do
not assert mathematical acceptance. Every receipt keeps `credit_issuance: false`.
The one-unit arithmetic is a disposable model fixture, not an award, account
credit, payment, or promise of transferable value.

An artifact differing from the approved export can be submitted under the correct
target and receive a definitive rejection. Wrong target/source/generation fields
are refused at admission. Unavailable or inconclusive checking changes dispatch
and observation metadata only; it cannot settle or refund the represented state.
A trusted operator can retry paused dispatch. Revoking and regranting the original
requester does not revive its old job authorization; a fresh admission is needed.

Multiple workers may perform the same bounded check. They cannot publish two
terminal effects. The design makes no at-most-once physical-computation claim.
An old prepared result is stale when its binding, grant, profile or row version
is stale; pausing dispatch metadata does not itself invalidate a good result.

SQLite uses WAL, `synchronous=FULL`, foreign keys, bounded busy handling and
independent connections. Immutable-record triggers and unique constraints
reinforce the application transaction. A pre-commit process crash rolls back
state, effect and receipt; a post-commit crash retains the winner for recovery.
The acceptance harness kills the actual worker at both points, then restarts it.

## Transport corrections

Real proof exports exercise Unicode that the original small stdio fixture did
not cover. The launcher now reads and writes UTF-8 correctly while applying its
128 KiB limit to encoded byte counts. JSON null is normalized explicitly, including
null JSON-RPC error IDs and nested checker receipt fields. Regression tests use
the actual subprocess and multibyte input, not only an in-process parser.
Python receipt encoding also matches the existing Elixir encoder's uppercase
hex escapes for control characters. A character-aware encoder preserves the
difference between a control character and literal backslash-u text; both are
covered by cross-language MAC checks.

The private Python channel has a fixed repository entry point, bounded frames,
correlated request IDs, duplicate-key refusal and a fixed error-code allowlist.
Client arguments cannot select commands, paths, profiles, principals or verdicts.
Timeout or protocol failure closes the channel. Explicit launcher restart and
durable idempotency resolve uncertain responses; the transport does not silently
repeat a possibly committed operation.

## Required evidence at the proposed revision

Acceptance requires three successful dedicated workflows at the same head:

1. The unchanged complete 12-stage core profile.
2. The MCP memory/transport regression suite, source-identity refusal controls,
   and the existing disposable pilot's Lean/Quint/real-replay acceptance.
3. The six-stage bridge profile: Lean proofs, independent Quint exploration and
   mutants, reviewed fixture preparation, real export stdio/SQLite/checker
   acceptance, mandatory real source MCP/worker acceptance, and compiled-Lean
   comparisons. Both runtime profiles must supply actual committed database
   inputs and complete persisted post-states, effects, versions and terminal
   receipts.

The bridge runner records before/after source inventories, exact Git commit/tree,
selected historical core, commands, exit codes, logs and artifact hashes. It
requires every stage in order, rejects omitted/failed/skipped stages, and refuses
source drift. Local development with `--allow-dirty` is explicitly marked as
uncommitted evidence. Hosted CI requires clean sources and the event's exact head.
The source stage checks an independent required-case inventory and refuses any
skipped, omitted, duplicated or failing case. Its prerequisites and replay
evidence are mandatory. Source compilation and MCP tests run inside the aggregate
before/after inventory; preparation of the pinned import bundle precedes it.

The independent Quint model is finite safety evidence with explicit domains and
queue exhaustion. Its named-invariant counterexamples test the claimed guards.
The compiled Lean/Python comparison is finite runtime correspondence evidence;
the theorem supplies the universal statement about the formal row function.
Source-job database observations exercise that row function with the trusted
checked premise. They do not establish executable correspondence between the
Python source validator and `SourceBoundary.Admissible`.

## Remaining premises and next milestone

The local operator, OS, Python/BEAM runtimes, database integrity and checker
executables remain trusted. Token validation, fresh SQL joins, SQLite atomicity,
the permanent request-ID map, effect-ID allocation, canonical JSON/HMAC handling
and the association of hashes with actual bytes are exercised by implementation
tests; they are not proved by the row theorem. Checker correctness and truth of
the controlled checker result remain explicit premises. Both replay programs
run on the same host, so this is not remote attestation or independent hardware.

The reviewed-export profile remains available. The separately provisioned
[bounded Lean source profile](BOUNDED_LEAN_SOURCE.md) adds a local operator-run
compiler for one theorem and one pinned mathlib environment. Its contract
includes source materialization, dual closure replay, and refusal and recovery
checks. The next source proof milestone is a fixed-contract accepted-effect
refinement lemma for `SourceBoundary.advance`, together with executable
evidence-projection comparisons if the runtime validator is claimed to implement
`Admissible`. Quint execution and UTCP exposure remain separate milestones.
