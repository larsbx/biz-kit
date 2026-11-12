# Authenticated reward adapter acceptance pilot

This package is a **local loopback HTTP and SQLite acceptance pilot** for one
prefunded reward slot at a time. Its balances are disposable fixture credits.
It is not a public service, a Biz-kit business-log writer, a Hawala/TigerBeetle
financial adapter, or a production authentication/settlement deployment.

The existing `reference/` remains pure. This adapter calls its actual reward
transition after authenticated admission and controlled proof checking, then
persists the resulting state, settlement event and request receipt in one
SQLite transaction. The runtime tests are finite implementation evidence;
they are not a formal refinement proof of Python, SQLite, HTTP or cryptography.

## Fixed proof profile

The operator prepares two exports from the reviewed, built
`ResearchExchange.Adapter` module:

- `ResearchExchange.Adapter.expected_fixture`: the approved true proposition.
- `ResearchExchange.Adapter.alternate_fixture`: a different true proposition,
  used to show that a valid proof for a different target is refused.

Preparation builds only reviewed repository source, audits both fixtures'
axiom dependencies, exports both closures, and replays both with the pinned
Lean kernel and independent lean4lean checker. The approved profile binds the
expected theorem, source file identities, toolchain lock, exact export bytes,
checker/library hashes and axiom policy. It accepts only that exact export.

The runtime does **not** compile contributor Lean, load contributor imports,
evaluate tactics, take executable paths from HTTP, or trust a client-supplied
verdict. A wrong digest is rejected before starting either checker. An exact
approved export must then pass both actual checkers with zero exit status and
their required completion markers. This narrow whitelist is not arbitrary
research validation or a sandbox for untrusted Lean elaboration.

From `proof_bank/research_exchange`:

```sh
python -m adapter_pilot.prepare_fixture \
  --lean-root /path/to/lean-4.35.0-linux \
  --output-dir /path/to/disposable-fixtures
```

In environments requiring the existing pinned application-path adapter, add
`--application-path-adapter /path/to/toolchain_app_path.so`. The runtime checks
its hash against `toolchains.lock.json`. No inherited `LD_PRELOAD`,
`LD_LIBRARY_PATH`, or contributor import path is passed to the checker.

Preparation writes `expected.export`, `alternate.export`, `profile.json` and
`preparation-receipt.json`. The receipt retains both checker outputs and axiom
dependencies. Its hashes detect ordinary drift on a trusted local host; they
are not signed remote attestation or proof against a privileged hostile host.

## Trusted provisioning

Provision a new disposable database with the Python API:

```python
import json
import secrets
from pathlib import Path
from adapter_pilot.store import Store

profile = json.loads(Path("/path/to/disposable-fixtures/profile.json").read_text())
store = Store("/path/to/disposable-pilot.sqlite")
store.initialize()
store.provision_slot("example", profile, reward=5, worker_a=10, worker_b=20,
                     funder=7, verifier_principal=30)

worker_a = secrets.token_urlsafe(32)
worker_b = secrets.token_urlsafe(32)
verifier = secrets.token_urlsafe(32)
store.provision_credential(worker_a, 10, "worker", ["example"])
store.provision_credential(worker_b, 20, "worker", ["example"])
store.provision_credential(verifier, 30, "verifier", ["example"])
```

The operator delivers tokens separately to their intended local clients. Only
domain-separated token hashes are stored. Do not put tokens in source, command
arguments, receipts, prompts or logs. Worker and verifier principals must be
distinct, and the exact verifier principal is part of immutable slot config.

`store.revoke_credential(token)` disables a credential.
`store.set_credential_enabled(token, enabled)` increments its epoch on each
actual enable/disable change. A revoke/regrant cycle therefore invalidates any
previously prepared verification. These are trusted offline APIs; there is no
HTTP provisioning or credential-administration endpoint.

Credit totals, principal IDs, versions, credential epochs, clocks and lease
durations have explicit signed-64-bit-safe bounds. Full SHA-256 commitments
are encoded as arbitrary-precision Nat values in canonical state JSON, not
SQLite INTEGER columns. Initial escrow is a fixture premise, not a funding
transaction or an issuance/conservation claim across real accounts.

## Loopback HTTP interface

```sh
python -m adapter_pilot.server \
  --db /path/to/disposable-pilot.sqlite \
  --lean-root /path/to/lean-4.35.0-linux \
  --port 0 --ready-file /path/to/ready.json
```

Only literal IPv4 loopback `127.0.0.1` is allowed. The ready file records the
selected port and process ID. Each request uses `Authorization: Bearer TOKEN`.
POST requests require `Content-Type: application/json` and a bounded explicit
Content-Length. Unknown/extra fields, duplicate JSON keys, invalid scalar
types, booleans masquerading as integers, noncanonical base64 and oversized
artifacts are refused. There is no TLS, OAuth provider, Internet listener,
MCP server or UTCP server in this pilot.

| Method/path | Exact JSON body | Authority |
| --- | --- | --- |
| `POST /v1/slots/{id}/lease` | `request_id`, `ttl_ms` | Active scoped configured worker |
| `POST /v1/slots/{id}/submit` | `request_id`, `generation`, `artifact_base64` | Active scoped lease-owning worker |
| `GET /v1/slots/{id}` | None | Active scoped credential |
| `POST /internal/slots/{id}/verify` | `request_id` | Exact configured active scoped verifier |

The internal verify endpoint triggers checking of the already stored immutable
candidate. It does not accept `trusted`, proof status, receipts, profile,
checker command, worker identity, payout destination or evidence fields.
There is no public `accept` endpoint. Worker identity comes from the verified
credential; bindings come from immutable configuration; artifact hash comes
from copied bytes; admission time and original lease deadline come from the
server clock.

Successful operations return `{slot_id, version, state, settlement}`.
Failures return `{error}` with a stable code and non-2xx status. Each completed
well-formed operation is permanently bound to its canonical request, operation
and slot under the authenticated principal's request ID. Identical retry
returns the saved response. Changed content under the same ID is a conflict.
Authorization is checked before returning a saved response. Domain refusals
and controlled-check failures can have retained error receipts; a new operation
needs a new request ID. Malformed/unauthenticated requests never acquire an
idempotency identity.

## Verification, commit and recovery

Verification snapshots the immutable candidate, artifact/profile/config
identities, row version, credential identity and epoch inside a short database
transaction. Both proof replays run outside that transaction. Commit takes
`BEGIN IMMEDIATE` and checks current credential role, scope, enablement, exact
verifier principal, epoch, candidate, profile/config and row version again.

Only successful controlled checking permits the internal call to
`reward_step(config, state, Accept(True, exact_candidate))`. The new state, one
unique settlement event and stored response/request binding commit together.
No response is sent before commit. An authorized retry can return an already
committed identical candidate outcome; it cannot create another payout.

SQLite uses WAL, `synchronous=FULL`, foreign keys, independent connections and
bounded busy handling. `store.inspect(slot_id)` is a trusted offline inspection
API returning state/version, settlement/request rows and the actual SQLite
durability settings. It never returns credentials or token hashes. This
single-host profile does not establish PostgreSQL conformance, replication,
backup recovery, hardware power-loss guarantees or exactly-once external
financial effects.

For process crash acceptance, trusted startup configuration can select:

```text
--failpoint before_commit --failpoint-request-id REQUEST_ID
--failpoint after_commit --failpoint-request-id REQUEST_ID
```

These call `os._exit` inside the service process before the transaction commit
or immediately after commit and before the response, respectively. They are
not HTTP fields or headers. A pre-commit crash must leave neither payout nor
settlement/request receipt. A post-commit lost response must leave all three;
restart/retry returns the original durable response.

Trusted race tests may use `--pause-after-verification PATHBASE
--pause-request-id REQUEST_ID`. After actual checker success, the service
writes `PATHBASE.ready` and waits at most 20 seconds for `PATHBASE.release`.
Tests can revoke/regrant the credential or advance the row version before
release and require refusal without settlement. No test hook is selectable
through the API.

## Remaining boundaries

The local operator, database integrity, OS, Python and checker runtimes are
trusted. Independent replay is independent checking software on this host,
not an independent machine or signed attestation. Uploaded source compilation,
real compute execution/metering, multi-slot/global accounting, rejection of
an invalid admitted candidate, scoped artifact publication, network security,
production identity/revocation, Biz-kit signed admission and financial
authority remain separate work. A timely admitted candidate stays frozen;
this slice adds no reject/reissue transition.
