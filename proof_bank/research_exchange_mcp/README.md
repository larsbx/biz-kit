# Bounded research exchange MCP adapter

Bounded local admission implementation for a nonprofit, open source collaborative research service.
Benefits are intended to be recognition and nonmonetary ecosystem credits.
No awards or credits are issued by this adapter. Credit allocation, expiry,
transferability and recognition governance remain policy decisions for review.
There are no monetary prices, payments, payouts or monetary settlement APIs.

This dependency-free Elixir package implements MCP **2025-11-25**, with a local
stdio transport and four tools. The default in-memory backend does not start automatically with Biz-kit,
open a listening socket, download libraries, execute artifacts, or launch Lean
or Quint. Libraries are operator-provisioned catalog entries, not live checkouts.
Mathlib and project libraries require separately reviewed snapshot/environment
entries. Only metadata and bounded submitted UTF-8 text are served at this stage.

The [disposable SQLite pilot](durable/README.md) opts into durable admission
and offline dual-checker replay for one reviewed Lean export.

| Tool | Required scope | Effect |
| --- | --- | --- |
| `library_discover` | `library:read` | List only authorized pinned library metadata |
| `proof_submit` | `proof:submit` | Store immutable artifact text and bound submission receipt |
| `verification_request` | `verification:request` | Queue one capability-bound, memory-only capacity reservation |
| `receipt_get` | `library:read` | Read a receipt belonging to the authenticated principal and accessible library |

The operator provisions high-entropy credentials with principal, expiry, exact
scopes and authorized library IDs. Only SHA-256 token hashes are stored. Token
validation occurs on each operation, including retries and discovery. The
principal is never accepted from a tool argument. Internal verifier, meter and
receipt MAC keys must be distinct and at least 32 bytes; contributor tokens
cannot reuse those keys. This is bounded local provisioning, not Internet OAuth.

## Reproduce without the umbrella or third-party dependencies

Requires Elixir 1.19.0 and OTP 27.3.4 (`:json` is part of OTP), Python 3.12+
and a Git checkout. Run from the repository root. The selected historical core
revision must be available locally; the first command fetches that exact revision.

```bash
snapshot_tool=proof_bank/research_exchange_mcp/tools/verify_core_snapshot.py
git fetch --no-tags --depth=1 origin "$(python3 -B "$snapshot_tool" --print-revision)"
python3 -B "$snapshot_tool"
python3 -B -m unittest discover -s proof_bank/research_exchange_mcp/tools -p 'test_*.py' -v
elixir proof_bank/research_exchange_mcp/test/format.exs --check
mkdir -p /tmp/research-exchange-beams
elixirc --warnings-as-errors -o /tmp/research-exchange-beams proof_bank/research_exchange_mcp/lib/research_exchange/*.ex
elixir proof_bank/research_exchange_mcp/test/run.exs
```

The tests generate their own local credentials and start an actual local stdio
subprocess. The child completes initialization, tool discovery, all four tool
calls, exact retries, conflicting-key refusals and retrieval of its actual
submission/job receipts. Every receipt preserves the complete binding and
keeps mathematical acceptance and credit issuance false. A separate shared-server
wire-decoder test checks cross-principal access to records that really exist;
two isolated child stores would not establish that authorization property.
The suite does not execute submitted Lean/Quint or call an external service.
For complete mathematical kernel acceptance, follow the separately pinned
[core verification profile](../research_exchange/README.md).

## Reviewed core identity

[`CORE_SNAPSHOT.json`](CORE_SNAPSHOT.json) is the common source for the MCP
receipt's core identity and both exchange CI workflows. It selects PR #336's
reviewed source revision `d6c07ef7b57e844c3aaad8d2c7dff938098a71bf` and manifest
`e46f8f6c12f790d6889085d072b58f92067004077a8b7f430abcb8433bbb0776`.
The current core package is byte-identical to that snapshot, including its
76 properties and terminal rejection/refund extension. This integration changes
neither its manifest nor its proof/toolchain pins.

The verifier checks the manifest stored at the named Git revision, its selected
digest and every file in the current core inventory. It rejects stale pins,
changed or extra source files, duplicate JSON keys and malformed identities.
CI additionally requires the exchange sources to match the checked-out commit.
The selected historical core revision and the current integration/workflow
revision are separate provenance fields. Receipt identity alone does not claim
that an MCP request executed the core.

Both workflows trigger for either package, shared documentation or either
workflow. The MCP job retains before/after source records and the actual test
log; the core job requires all 12 proof/model/HTTP stages and retains its full
receipt. The [integration acceptance contract](../../docs/proof-bank/research-exchange/INTEGRATION_ACCEPTANCE.md)
records the intended boundary and remaining refinement work.

## Local transport configuration

`bin/stdio.exs` reads `RESEARCH_EXCHANGE_CONFIG`, the absolute path to an
operator-owned JSON configuration file, and `RESEARCH_EXCHANGE_TOKEN`, the
credential supplied to this trusted local launcher out of band. Protect the
file, process environment and BEAM runtime from contributor access. A hostile
process with the same host privileges is outside this prototype's boundary.
Do not expose this process, its internal module API or Erlang distribution to
remote agents. No HTTP authentication or Internet transport is claimed.

Configuration keys are `libraries`, `tokens`, `receipt_key_base64`,
`worker_key_base64`, `meter_key_base64`. Library IDs map to objects containing
`id`, `engine` (`lean` or `quint`), 40-character lowercase Git `revision`,
64-character `snapshot_sha256`, `environment_sha256`, `policy_sha256`, and a
positive integer `generation`. Token hashes map to `principal`, `expires`
(Unix seconds), `libraries`, and `scopes`. The test contains a complete generated
configuration; no working credential or deployment configuration is committed.

```bash
elixir proof_bank/research_exchange_mcp/bin/stdio.exs
```

Negotiate `initialize` with protocol `2025-11-25`, send
`notifications/initialized`, then call `tools/list` and `tools/call`. Standard
output contains newline-delimited JSON-RPC only. The transport rejects messages
over 128 KiB, JSON batches, invalid request IDs and duplicate JSON keys. Tool
arguments use exact key sets. Artifacts are limited to 64 KiB; the process holds
at most 128 submissions, 128 jobs and 256 idempotency keys. Limits apply per
process, not globally. One process serializes admission and retry handling.

`proof_submit` requires `idempotency_key`, `library`, `revision`,
`snapshot_sha256`, `generation`, `target`, `artifact`, `artifact_sha256`.
`verification_request` requires `idempotency_key`, `submission_id`.
`receipt_get` requires `id`. Unknown fields, including contributor identity,
success claims, verifier trust, stop acknowledgments and settlement fields, are
rejected. Each idempotency key is scoped to the principal across both writing
tools. Exact retries return the original receipt; conflicting reuse fails.

## Evidence and integration boundary

Every receipt binds contributor, library, source revision and snapshot digest,
artifact digest, target, catalog generation, environment and policy digests,
and the reviewed core identity. Job capabilities additionally bind a random
nonce, process boot identity, submission ID and five-minute expiration. The
original artifact is held by value. A source or artifact hash is an identity
commitment, not proof that a checkout exists or that the artifact proves its
declared target. The future controlled executor must establish those facts.

Receipts use domain-separated SHA-256 and HMAC-SHA-256 over canonical UTF-8 JSON:
string keys sorted by bytes, no whitespace, no floats or atom keys. There is no
Unicode normalization. `Evidence.canonical/1` is the normative encoder (not
RFC 8785/JCS). The envelope contains `payload`, `sha256`, and `server_mac`.
The MAC provides local shared-key authentication; it is not a publicly verifiable
signature or independent proof of execution.

`Server.job/3` is an internal worker port guarded by a separate operator key.
`Server.observe/3` accepts a MAC over the complete job binding, capability,
outcome and evidence digest. `Server.observe_compute/3` requires a separate
meter-key MAC, exact binding, bounded CPU-millisecond observation and evidence
digest. Each observation kind is consumed once; stale, cross-job and cross-boot
capabilities fail. Neither port is an MCP tool. The result is an authenticated
**observation**, not kernel acceptance, physical metering or an award. Receipts
always contain `mathematical_acceptance: false` and `credit_issuance: false`.
No stop acknowledgment is synthesized. Capacity remains held for this process
lifetime; there is no refund or settlement path.

`ResearchExchange.Ports` defines the future durable transaction/outbox contract.
It is deliberately not wired to a database or worker. Before execution, implement
an immutable source/artifact materializer, approved environment and license
policy, network-disabled sandbox with CPU/memory/time/output limits, controlled
Lean axiom/target checking and Quint commands, independently authenticated meter,
durable reservation versions and atomic outbox dispatch. Never interpret a
client's command, checker exit code or JSON success claim as acceptance. Bind
raw evidence and independently checked theorem statements to the same artifact.

The adapter does **not** call the core's authority-bearing `Reward.accept` or
`Reservation.settle`, nor provide a production refinement of those definitions.
The four core binding fields are abstract natural-number identities; translating
these concrete digest commitments into a collision-resistant identity registry
and proving the persisted representation relation remains future work. The
existing reward/accounting arithmetic is historical formal machinery; using it
for nonmonetary quotas requires a separately specified allocation policy.

Restart loses reservations, replay records, artifacts and receipts. Multiple
processes do not share a ledger. Accepted observations may outlive credential
revocation, but cannot authorize execution or credits; outstanding work must be
revalidated against current grants before any future dispatch/acceptance.
This is executable adapter test coverage, not complete service-level verification.

Protocol references: [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).
