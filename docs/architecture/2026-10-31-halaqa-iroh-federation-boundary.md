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
[`11eb6309ec6caccb6aab3c821eba2311881c9ba0`](https://github.com/larsbx/halaqa/blob/11eb6309ec6caccb6aab3c821eba2311881c9ba0/.polyglot/halaqa-federation-draft-0/contract.md).
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
Python format/signed oracles, 40 unsigned vectors and 48 signed vectors. `source-pin.json`
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

The [signed draft-1 contract](https://github.com/larsbx/halaqa/blob/11eb6309ec6caccb6aab3c821eba2311881c9ba0/.polyglot/halaqa-federation-signed-draft-1/contract.md)
adds Ed25519 verification using OpenSSL and an explicit proposed signing domain.
The signature binds the exact original candidate bytes, key ID and lifetime;
changing inner JSON whitespace invalidates it. No JSON canonicalization or
prehash is assumed. Separate local TEST pins bind the actor, key, recipient,
circle, charter digest and epoch and supply the clock/revocation state.

All 48 signed cases are synthetic: 8 signature-valid and 40 refused. They cover
cross-domain signatures, forged/changed signatures, candidate/payload tampering,
wrong recipient/context, revoked test keys, key substitution, expiry and malformed
encodings. Test signatures were generated through cryptography and checked
through OpenSSL; this is not independent cryptographic implementation evidence.
No new Python dependency is introduced; an Ed25519-capable OpenSSL CLI is needed.

Success is `SIGNATURE_VALID_AUTHORITY_UNVERIFIED`, with authority and production
receiver flags false. TEST pins are not actual identity succession, fresh
revocation evidence, charter adoption or permission. The verifier is stateless:
expiry checks do not establish durable replay prevention or effect idempotency.
Neither experiment has a live ingress or can invoke BuzzBridge/domain admission.

Run:

```sh
python3 tools/check_halaqa_federation_draft.py
python3 -m unittest discover -s tools -p 'test_halaqa_federation_draft.py' -v
```

The focused CI workflow runs the reference, independent Elixir and independent
Rust checks in separate jobs. No Iroh connection is opened. No application,
production runtime dependency, ingress, shared schema or business writer is added.

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
matches all 48 signed cases, including exact positive transcript/payload bytes
and all refusal reasons; its 8 ExUnit checks pass locally. Both implementations
use OpenSSL-backed cryptography, so this is independent protocol/decoder evidence,
not independent cryptographic primitive evidence. Rust corpus agreement is
recorded below; actual identity succession/current revocation sources, durable
replay and live Iroh remain open.
The focused CI workflow runs Python and Elixir in separate jobs.

### Independent Rust signed verifier — 2026-11-01

[`tools/halaqa_signed_rust`](../../tools/halaqa_signed_rust/README.md) adds an
isolated test executable using an independent decoder/transcript implementation
and Dalek's Rust Ed25519 primitive. It matches all 48 source-pinned signed cases,
including the eight exact payload/transcript pairs and 40 refusal reasons.
Fifteen Rust tests add fresh signed mutations and bounded-decoder edge checks.
The original Python sources and both fixture corpora remain byte-identical.
The focused workflow adds locked/offline Rust checks and uploads exact-head
execution artifacts. A local execution receipt is retained beside the tool.

The expanded probes uncover a material **weak TEST-key acceptance difference**:
Python/OpenSSL and the current Elixir OTP verifier accept an identity-point
public key and R with zero S; Dalek `verify_strict` refuses it. This requires an
owner decision and a new reviewed profile/vector revision, not relaxing Rust.
The unsigned lone-surrogate sender is refused as `identifier` by Python and
`invalid_json` by Rust. Integer `-0` and exponent overflow behavior agree after
preserving numeric lexemes separately from original signed bytes. The diagnostic
runner records known disagreements explicitly; they do not count as conformance.
The unsigned 40-case probe therefore has one exact-reason difference.

Corpus agreement is demonstrated, not a blanket equivalence or F2 completion
claim. Strict key/point/scalar validation, production signing, real identity and
current revocation/governance contracts still need separate review. No crate is
linked into the Iroh sidecar, Port or admission path. Both authority and production
receiver flags stay false, and no replay or business effect is committed.

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
| F2 — Verified boundary | Python/OpenSSL, independent Elixir and Rust agree on 48 experimental signed cases; weak-key acceptance and decoder edge differences, actual identity/evidence sources and production admission remain pending |
| F3 — Native delivery | Two independent installations, application HTTP disabled, bounded streams, configured direct/relay tests, durable inbox/outbox and original-ID status reconciliation across lost ACKs, partition and restart |
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
