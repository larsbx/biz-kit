# Proposed Halaqa federation boundary over Iroh

Date: 2026-10-31 (America/New_York).
Status: **Proposed; offline conformance preparation only.**

## Direction and sources

Use Halaqa federation over Iroh to exchange collaboration candidates,
provenance and evidence between independently administered installations.
ActivityStreams is a representation profile; ordinary HTTP ActivityPub is an
optional compatibility adapter. Native peer exchanges should not require
public HTTPS servers. Iroh relay infrastructure may itself use web transports.
The native binding is not wire-compatible with unmodified ActivityPub servers.

The semantic proposal and exact-byte format corpus are owned in
[Halaqa PR #9](https://github.com/larsbx/halaqa/pull/9), pinned for this slice at
[`7f677f7f82bd9c2d8f020996dc5352bc59a364af`](https://github.com/larsbx/halaqa/blob/7f677f7f82bd9c2d8f020996dc5352bc59a364af/.polyglot/halaqa-federation-draft-0/contract.md).
Halaqa's canonical event, authority and replication formats remain controlled
placeholders. The draft does not adopt those formats or create a gateway.

Inspected biz-kit baseline: `66b4ec160a1f2cae6f31b027cfad52f8960cafcc`.
Existing implementation boundaries:

- [`native/marketplace_gossip`](../../native/marketplace_gossip/README.md):
  supervised Rust/Iroh sidecar for public discovery, publisher signatures,
  pinned actor keys, durable projections, scoped catch-up and freshness.
  This pilot currently disables relays and uses configured direct addresses.
- [`FederationService.GossipWorker`](../../apps/federation_service/lib/federation_service/gossip_worker.ex):
  Elixir Port lifecycle and durable-source-driven work. This is the reuse
  point for future bounded streams; no new generic service framework is needed.
- [`CoopSubstrate.Halaqa.BuzzBridge`](../../apps/coop_substrate/lib/coop_substrate/halaqa/buzz_bridge.ex):
  transport-neutral conformance boundary. Its validity, membership, delegation
  and policy inputs are harness assertions, not verified remote claims.
  Its current production-effect gate remains disabled, as documented in the
  [bridge contract](../../apps/coop_substrate/docs/halaqa_buzz_integration_v1.md).
- [`BizKit.Cluster`](../../apps/biz_kit_cluster/lib/biz_kit/cluster.ex):
  internal distributed Erlang coordination. Native federation does not replace
  cluster consensus/fencing or connect independent peers to this trust domain.

## Responsibilities

| Component | Role | What reception never implies |
| --- | --- | --- |
| Iroh | Authenticated endpoint connections, streams, gossip, blob transport | Actor authorization or semantic evidence validity |
| Halaqa gateway and designated subsystem contracts | Typed candidates, protocol verification, evidence/context routing and canonicalization | Power to invent governance or bypass a domain owner |
| SANAD+ | Provenance, attestations, commitments, disclosed evidence | Truth solely from possession of signed bytes |
| UṢŪL-K and recognized authorities | Applicable normative resolution and its independently checked evidence | Authority derived from topic membership or a software role label |
| Biz-kit domains | Current grants/preconditions, signed business admission and effect receipts | Remote permission to write another home's facts |
| Hawala | Separately governed native financial protocol and authority | Settlement from a business receipt or federation ACK |
| ActivityStreams / HTTP gateway | Supported representations and external interoperability | Authority amplification or replacement of the signed original |

The existing extension host work is complementary:
[PR #224](https://github.com/larsbx/biz-kit/pull/224) and
[issue #225](https://github.com/larsbx/biz-kit/issues/225) cover host lifecycle,
wire negotiation and actual authority adapters. This proposal does not depend
on their unmerged implementation or claim runtime activation is delivered.

## First executable slice: offline format conformance

`tools/halaqa_federation_draft/` holds test-only copies of Halaqa's proposed
Python format/signed oracles, 40 unsigned vectors and 74 signed vectors. `source-pin.json`
records the full source commit, original paths, SHA-256 and Git blob hashes.
`tools/check_halaqa_federation_draft.py` checks fixed paths and both hashes
before executing the captured verified Python source bytes. It bypasses stale
bytecode and substitutes only the verified dependency during signed-module
loading, restoring any preloaded module afterward. Nothing is downloaded at
runtime or CI.

These are pinned copies of reference implementations, **not independent
Python/Elixir/Rust agreement**. The reviewed pin selects the source; local
hash checks alone cannot prove commit inclusion, source authority or adoption.
At preparation time the copied files were verified against GitHub reads at
the exact pinned commit. Future repins must repeat that source verification.

The 6 unsigned positive vectors return `FORMAT_ONLY_UNVERIFIED`; the 34 negative
vectors exercise exact refusal codes. Payload digests bind original decoded
bytes, including whitespace. Draft-0 has no signature or grant fields and
must never be accepted by a live network ingress. It is not the existing
marketplace gossip envelope, a HAI artifact, or a SANAD+ transcript.
Payload semantics, evidence closure, actor identity, current charter/epoch,
delegations, privacy and authority are unverified even on format success.

## Signed experiment: exact bytes and local TEST bindings

The [signed draft-2 contract](https://github.com/larsbx/halaqa/blob/7f677f7f82bd9c2d8f020996dc5352bc59a364af/.polyglot/halaqa-federation-signed-draft-2/contract.md)
adds Ed25519 verification using OpenSSL and an explicit proposed signing domain.
The signature binds the exact original candidate bytes, key ID and lifetime;
changing inner JSON whitespace invalidates it. No JSON canonicalization or
prehash is assumed. Separate local TEST pins bind the actor, key, recipient,
circle, charter digest and epoch and supply the clock/revocation state.

All 74 signed cases are synthetic: 8 signature-valid and 66 refused. They cover
cross-domain signatures, forged/changed signatures, candidate/payload tampering,
wrong recipient/context, revoked test keys, key substitution, expiry and malformed
encodings. Draft-2 adds 25 weak/noncanonical point or scalar regressions and
refuses the legacy draft-1 schema. Test signatures use disclosed synthetic
seeds and were generated through cryptography; Python verifies through OpenSSL.
No new Python dependency is introduced; an Ed25519-capable OpenSSL CLI is needed.

Success is `SIGNATURE_VALID_AUTHORITY_UNVERIFIED`, with authority and production
receiver flags false. TEST pins are not actual identity succession, fresh
revocation evidence, charter adoption or permission. The verifier is stateless:
expiry checks alone do not establish durable replay prevention or effect idempotency.
The separate operational receipt experiment below adds test persistence, not
production replay/admission acceptance.
Neither experiment has a live ingress or can invoke BuzzBridge/domain admission.

Run:

```sh
python3 tools/check_halaqa_federation_draft.py
python3 -m unittest discover -s tools -p 'test_halaqa_federation_draft.py' -v
```

The focused CI workflow runs Python, Elixir, Rust, isolated PostgreSQL and
experimental direct-Iroh jobs. Only the explicit Iroh fixture job opens peer
connections: default direct loopback or an explicit TLS relay-only profile.
Public discovery/default relays remain disabled. The Rust crate has its own locked test dependencies;
no application runtime dependency, production ingress, shared schema or business
writer is added by this slice.

## Next implementation gates

### Independent Elixir signed verifier — 2026-11-01

`tools/halaqa_signed_draft.exs` independently implements bounded JSON decoding,
duplicate-key refusal, candidate validation, exact signing-byte construction,
external TEST policy binding and Ed25519 verification through OTP `:crypto`.
It does not invoke Python or import the reference implementation. OTP 27's
`:json.decode/3` callbacks refuse duplicates before map construction. No new
Mix dependency or production application module is introduced.

Run `elixir tools/check_halaqa_signed_draft.exs` and
`elixir tools/test_halaqa_signed_draft.exs` on Elixir 1.19 / OTP 27. The verifier
matches all 74 signed cases, including exact positive transcript/payload bytes
and all refusal reasons; its 8 ExUnit checks pass locally. Both implementations
use OpenSSL-backed cryptography, so this is independent protocol/decoder evidence,
not independent cryptographic primitive evidence. The Rust consumer below adds
a separate primitive implementation. Actual identity succession/current revocation
sources, durable replay and live Iroh remain open.

### Independent Rust verifier and strict draft-2 — 2026-11-01

`tools/halaqa_signed_draft_rs/` independently decodes and verifies the signed
experiment with RustCrypto `ed25519-dalek` 2.2.0, SHA-256 and a duplicate-refusing
Serde visitor. It implements the proposed transcript and local TEST policy
without calling Python, Elixir, OpenSSL or the marketplace runtime. The standalone
CLI bounds corpus input to 2 MB and frame input to the profile limits. Its locked
Cargo dependencies are isolated from application/native production crates.

The Rust strict verifier exposed a backend discrepancy: the previous OpenSSL/OTP
experiment accepted a synthetic identity-key/trivial signature. Signed draft-2
adds explicit canonical field-coordinate, small-order A/R and scalar-range
refusals before OpenSSL/OTP verification. The contract lists the exact rules and
primary sources. Rust enforces canonical coordinates and uses dalek's weak-point
checks plus `verify_strict`. Both schema and domain change; old draft-1 frames
are refused rather than reinterpreted. Historical Halaqa draft-1 artifacts remain.

All three consumers agree on the 74 draft-2 cases, exact positive transcript and
payload bytes, and refusal reasons. Rust's 6 tests, formatting and clippy pass;
Elixir's 8 tests and the 7 Python pin tests pass. Halaqa's 8 signed-reference
tests include a control proving 25 bad encodings cannot reach OpenSSL. This is
finite cross-implementation evidence, not a crypto audit, complete equivalence,
production identity validation or authority adoption.

```sh
cargo fmt --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml --check
cargo clippy --locked --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml
cargo run --locked --manifest-path tools/halaqa_signed_draft_rs/Cargo.toml
```

CI installs Rust 1.99.1 and runs those commands. PR #226 is merged at
`a2e13ea58465fbedb20dbf14934f9378c7e70e5d`; this follow-up does not reinterpret its
queued hosted checks as successful validation. No live receiver or production replay store
is enabled by this change.

### PostgreSQL receipt/replay experiment — 2026-11-01

The [receipt experiment](../../tools/halaqa_receipt_draft/README.md) adds an
isolated operational SQL schema and Python fixture adapter, following the
selected PostgreSQL/Redis storage responsibilities. It retains full original
candidate/wire/TEST-policy evidence under `(recipient, sender, message_id)`.
A committed identical candidate returns its original receipt even after
re-signing; different exact bytes retain conflict evidence without overwriting
the original. Epoch changes cannot reset an actor's message ID. Local status
reconciliation survives signature expiry without re-admitting that message.

The adapter verifies with the captured draft-2 reference before SQL, and returns
no receipt until COMMIT succeeds. READ COMMITTED, synchronous commit and normal
WAL durability are explicit requirements. A unique scoped key serializes
competing inserts; no global business-log lock, Redis dependency, domain writer
or existing discovery-store migration is introduced. SQL is operational storage,
not a signature or authority verifier. All receipts remain `STORED_TEST_ONLY`.

Fourteen integration tests pass against a disposable PostgreSQL 16.15 cluster,
covering concurrent duplicate/conflicting backends, rollback, full evidence,
lost ACK, immediate server crash/restart, unavailability, scope/epoch binding,
refusal before SQL and append-only role controls. The experiment README records
the local ownership shim and limits of this evidence; standard hosted acceptance
is a separate CI job. The 7 Python pin/mutation tests also pass with the shared
captured-source loader. The receipt/storage layer itself enables no network
listener, actual identity/current revocation source, canonical admission or
business effect. F3/F4 remain open.

### Durable sender outbox and local reconciliation — 2026-11-01

The receipt experiment now also retains immutable sender intent and first wire
bytes, creating its pending work row atomically. Before any peer callback,
`begin_attempt` commits `UNKNOWN` and advances a generation. Matching completion
records a bound remote retention receipt or original-ID content conflict;
terminal results cannot reactivate. Stale generations cannot overwrite a later
attempt. Original IDs and candidate bytes persist through retries, restarts and
lost acknowledgements; no replacement business command is created.

`tools/halaqa_outbox_draft.py` queries original-ID status before transmission.
Known matching retention can be reconciled after signature expiry without
re-admission. A strict missing result requires current sender TEST verification
and separate receiver TEST verification before sending the original wire.
Expired unsent work stays unknown pending an explicit envelope-refresh contract.
Scoped pending pages contain at most 16 results and must periodically rescan
from zero; sequence IDs are not complete-prefix watermarks. No Redis runtime,
new generic scheduler, business writer or production dependency is added.

Sixteen sender integration tests pass in addition to 14 receiver tests and
7 pin/mutation tests (37 Python tests). They use two databases on one disposable
PostgreSQL cluster with separate commit boundaries and in-process callbacks.
They demonstrate custody, generation fencing, strict reply binding, lost-ACK
reconciliation and crash recovery. They do not establish independent hosts,
authenticated Iroh peers/status replies or direct/relay delivery by themselves.
The transport experiment below adds local direct-path evidence. The experiment
README records the state transitions and remaining acceptance.

### Pinned direct Iroh experiment — 2026-11-01

`tools/halaqa_iroh_draft_rs/` and `tools/halaqa_iroh_draft.py` replace the
in-process fixture callback with actual Iroh 1.4.1 QUIC client/server processes.
The dedicated ALPN, length-prefixed frames, exact byte/EOF limits and deadlines
are documented in the receipt experiment. Each request has a fresh challenge;
client/server check configured endpoint IDs before trusting a response or
allowing a host callback. The host maps that pin to a local synthetic actor pair
and still verifies signed candidate/context evidence before SQL commit. Transport
endpoint identity is not production actor authority or domain admission.

The Minimal endpoint clears default IP transports, binds only loopback, disables
relays and configures no public lookup/publisher. Only explicit loopback IP targets
are permitted. No application HTTP server/client is started. This preserves the
original IDs/wire bytes, SQL custody and generation fences; it changes neither
marketplace gossip nor ordinary ActivityPub interoperability.

Seven native integration tests pass, including rejected client/server pins,
scoped status, stale host challenges, malformed/oversized messages and current
receiver TEST revocation/signature refusal. The lost post-commit reply case
restarts the receiver sidecar with its original endpoint key, then reconciles
retention after expiry using a fresh status request without redelivery. The
Iroh crate's 5 tests, formatting, clippy and locked build pass. All 44 Python
checks pass (7 pin, 14 receiver, 16 sender, 7 native transport). This is direct
loopback and separate-database evidence on one host; configured relays, independent
installations, real identity/disclosure sources and production adapters remain
required for F3/F4. Exact-head hosted CI is separate evidence.

### Verified relay paths and separate-host handoff — 2026-11-01

The same Iroh 1.4.1 sidecar now has an explicit relay-only configuration with
normal TLS verification against supplied CA roots. It removes all direct-IP
transports and requires a relay-only target. Both ends record and check selected
Iroh paths, received stream frames and byte counters; a configured URL alone
cannot count as relay delivery. The controlled local relay is endpoint-allowlisted.
Application HTTP remains disabled; relay infrastructure itself uses HTTPS.

Seven relay/runner cases pass, covering actual relay traffic, certificate and
endpoint refusal, mixed-path rejection, missing path evidence, outage/restart
reconciliation and a labeled one-host role rehearsal with report-mutation
controls. The full current set has 51 Python tests and 6 Iroh Rust tests, plus
formatting/clippy/locked build. The new [separate-host runner handoff](2026-11-01-halaqa-two-host-acceptance.md)
requires clean exact-revision sources and matching public reports but deliberately
does not certify physical-host provenance. No separate installations have been
configured or executed here. Their actual administration/host evidence, governing
identity/disclosure inputs and production Elixir/admission remain open.

The broader federation run at `68ffa46608428fc4e61bbe23c1dfa8e3f1baa1e5`
failed at its dependency audits, before the Elixir two-node acceptance suite.
Its Rust formatting, clippy, tests and build passed. The four affected lock
entries are corrected in the [dependency ledger](../security/remaining-dependencies-2026-10.md#november-1-federation-ci-audit-repair).
The new verifier does not waive the existing broad acceptance gates.

With the corrected lock, local full audit reports zero findings. The staged
federation harness passes 17 core tests, a 107-case service suite (2 test-mode
skips), and the separately run production-compiled HTTPS listener check.
The remaining native-gossip case has no local sidecar executable. Independent Elixir
and the 7 Python pin/reference tests pass separately. New-head hosted native
Iroh/umbrella checks remain required; these local results do not close F3.

| Stage | Required result |
| --- | --- |
| F0 — This PR | Pinned offline format oracle/corpus, mutation checks and implementation map |
| F1 — Halaqa owner decisions | Offline signed grammar/fixtures now available for review; immutable governing sources, actual producer/verifier, succession, disclosure, current epoch and replication/conflict decisions remain pending |
| F2 — Verified boundary | Python/OpenSSL, independent Elixir/OTP and Rust/dalek agree on 74 experimental signed cases; actual identity/evidence sources and production admission remain pending |
| F3 — Native delivery | PostgreSQL custody, pinned direct/relay paths and runner rehearsal have 44 integration tests. Still required: actual independent-installation execution/provenance, production identity/disclosure and unknown-outcome reconciliation across network partition/restart with application HTTP disabled |
| F4 — Domain admission | Real current biz-kit grants, canonical signed admission, durable effect IDs and mutation-time revocation checks; no dual writer or direct remote execution |
| F5 — Optional HTTP interoperability | Preserve original IDs/evidence, make gateway signing roles explicit, and test external ActivityPub separately |

F3 receipt persistence must specify its relationship to business admission.
Retain permanent same-ID/same-content replay results and same-ID/changed-content
conflicts. Redis work delivery is reconstructible from durable owners, per the
[storage contract](2026-10-30-postgres-event-log-redis-consolidation.md).
No global total order, cross-node ACID or exactly-once external effect is claimed.
Keep UNKNOWN, AMBIGUOUS, CONTESTED, UNVERIFIED, CONFLICTING and OUT-OF-SCOPE
distinct wherever the respective verification contract requires them.

## Compatibility and removal

Keep existing HTTPS discovery, gossip wire contracts and authority gates in
place until the relevant native consumers pass F1–F4. Later make HTTP
federation optional rather than requiring every independent installation to
serve it. Browser/UI hosting remains its own application choice.

Removing this experiment deletes its offline tools, fixture snapshot and CI
lane; it changes no ledger or external effect. Never downgrade a future signed
profile to unsigned draft-0. A live migration must preserve signed originals,
IDs, tombstones, revocations and receipts and explicitly fence prior writers.


### Additional Rust regressions and exact-head evidence — 2026-11-01

The follow-up to PR #229 reuses `tools/halaqa_signed_draft_rs` rather than adding
a second verifier. Nineteen Rust tests now cover fresh signed payload/signature,
context, revocation, expiry and malformed-input mutations in addition to all 74
pinned draft-2 cases. Raw numeric lexemes preserve integer `-0` while refusing
floats and numeric overflow without changing the original signed transcript.
Fixed-size key/signature lengths are checked before allocation. The standalone
runner accepts only its compiled, SHA-256-anchored corpus and checks exact counts;
caller-selected corpora/frames do not enter it.

`tools/check_halaqa_rust_differential.py` independently reproduces the resolved
weak-key refusal and records the remaining lone-surrogate refusal-code difference
(Python `identifier`, Rust `invalid_json`). That diagnostic is not counted as
signed conformance. Integer-zero and overflow probes now agree. The input-hashed
local receipt and reproduction guide are beside the crate; CI artifacts capture
the exact tested head and output. No production contract or live path changes.
