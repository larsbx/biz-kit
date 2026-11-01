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
[`ba418bc3154130620565521a98c8eff4b4a83d04`](https://github.com/larsbx/halaqa/blob/ba418bc3154130620565521a98c8eff4b4a83d04/.polyglot/halaqa-federation-draft-0/contract.md).
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

`tools/halaqa_federation_draft/` holds a test-only copy of Halaqa's proposed
Python format oracle and 40 exact-byte synthetic vectors. `source-pin.json`
records the full source commit, original paths, SHA-256 and Git blob hashes.
`tools/check_halaqa_federation_draft.py` checks fixed paths and both hashes
before executing that local oracle. Nothing is downloaded at runtime or CI.

This is a pinned copy of one reference implementation, **not independent
Python/Elixir/Rust agreement**. The reviewed pin selects the source; local
hash checks alone cannot prove commit inclusion, source authority or adoption.
At preparation time the copied files were verified against GitHub reads at
the exact pinned commit. Future repins must repeat that source verification.

The 6 positive vectors return `FORMAT_ONLY_UNVERIFIED`; the 34 negative
vectors exercise exact refusal codes. Payload digests bind original decoded
bytes, including whitespace. Draft-0 has no signature or grant fields and
must never be accepted by a live network ingress. It is not the existing
marketplace gossip envelope, a HAI artifact, or a SANAD+ transcript.
Payload semantics, evidence closure, actor identity, current charter/epoch,
delegations, privacy and authority are unverified even on format success.

Run:

```sh
python3 tools/check_halaqa_federation_draft.py
python3 -m unittest discover -s tools -p 'test_halaqa_federation_draft.py' -v
```

The focused CI workflow runs the same offline checks. It neither boots Elixir
nor opens an Iroh connection. No application, runtime dependency, production
ingress, shared schema or business writer is added by this slice.

## Next implementation gates

| Stage | Required result |
| --- | --- |
| F0 — This PR | Pinned offline format oracle/corpus, mutation checks and implementation map |
| F1 — Halaqa owner decisions | Immutable governing sources; actual producer/consumer designation; signed byte grammar; actor/key succession; disclosure, epoch, dependency and replication/conflict rules |
| F2 — Verified boundary | Independent Rust/Elixir implementation on signed vectors; remote validity flags cannot enter the Buzz bridge; altered scope/audience/evidence, revoked keys and stale epochs refuse |
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
