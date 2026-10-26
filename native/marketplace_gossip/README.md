# Experimental Halaqa-scoped marketplace gossip

This opt-in adapter transports the **existing** marketplace listing-v1
Create/Update/Delete activities and exact public metadata over iroh-gossip.
It adds no business command, ledger writer, reservation or payment path.
It is a working same-implementation discovery experiment, not an adopted
Halaqa replication protocol or third-party ActivityPub interoperability claim.

## Boundary

- Independent installations hold their own journal and Ed25519 endpoint seed.
- A local committed publication wakes a subscriber worker after journal sync.
  The worker broadcasts on a scoped gossip topic; no recipient polls a market
  HTTP endpoint or needs a Follow/Accept handshake on the HTTP transport.
- Iroh authenticates the immediate connection's endpoint ID. A separately
  signed application envelope authenticates the original publisher through
  forwarding neighbors. The receiving host explicitly pins each seller actor
  URL to an Ed25519 public key. Neither a topic ID nor a transport neighbor
  establishes seller identity or business permission.
- Halaqa ID, charter digest and epoch isolate the topic and signed envelope.
  These are operator-supplied routing context. A digest's shape does not prove
  charter adoption, membership, delegation, a SANAD attestation or effect authority.
- A verified event is durably queued before projection. The shared projection
  reducer retains immutable origins, increasing revisions, terminal tombstones
  and source attribution. Same-ID/different-payload events conflict. HTTP and
  gossip receipts check each other's activity IDs and cannot use the other
  transport to mutate an already acknowledged activity.
- Inline metadata is covered by the publisher signature and validated by
  `FederationCore.Marketplace`; its declared metadata URL stays origin-bound.
  The gossip path does **not fetch** that URL, expand JSON-LD or dereference
  fields supplied by a neighbor. No HTTPS actor discovery is required on this
  transport: the administrator's explicit actor/key pin is the trust root.

The Halaqa repository currently supplies no adopted gossip wire contract.
This implementation lives in biz-kit and does not fill Halaqa governance,
replication or authority placeholders. It is removable without changing local
business ledgers. Its envelope is a candidate transport format only.

## Build and run

Use Linux, Elixir 1.19 / OTP 27, Rust 1.99.1 and a local persistent filesystem.
The existing `flock` single-writer requirement applies. Build the pinned native
binary and generate a distinct raw 32-byte endpoint seed for each installation:

```sh
cargo build --locked --manifest-path native/marketplace_gossip/Cargo.toml
umask 077
openssl rand -out /run/keys/marketplace-endpoint.key 32
```

Start the existing discovery Store under the host supervisor. Build a service
configuration with its canonical seller URL and **no HTTP delivery peers**.
The private HTTP signing key is unused by this transport:

```elixir
service = FederationService.config!(
  actor: "https://alpha.example/actors/shop", store: MyDiscoveryStore,
  peers: [], private_key: nil)

config = FederationService.Gossip.config!(service,
  seed: File.read!("/run/keys/marketplace-endpoint.key"),
  scope: %{"halaqa_id" => "public-market", "charter_hash" => reviewed_digest, "epoch" => 1},
  publisher_keys: %{
    service.actor => alpha_endpoint_key_hex,
    "https://beta.example/actors/shop" => beta_endpoint_key_hex
  })

{FederationService.GossipWorker,
 config: config,
 executable: "/opt/biz-kit/bin/bizkit-marketplace-gossip",
 key_file: "/run/keys/marketplace-endpoint.key",
 bind: "0.0.0.0:7443",
 allowed_endpoints: [beta_endpoint_key_hex],
 peers: [%{"id" => beta_endpoint_key_hex, "addrs" => [%{"Ip" => "198.51.100.20:7443"}]}]}
```

The sample address is documentation-only; supply a reachable administrator-
configured address. `GossipWorker.address(worker)` returns the actual local
endpoint address after startup. Endpoints and addresses are independent of
seller URL hostnames; possession of an endpoint key alone cannot claim a URL.
Bootstrap addresses and incoming endpoint allowlists are local configuration,
not remote grant assertions. Stop/restart the worker with reviewed pins to
rotate/revoke a key. Republish with a new accepted source event and revision
after rotation; old activity receipts are retained and cannot be rewritten. Queued events recheck the current pin before projection;
accepted results with obsolete pins/scope are hidden by the discovery view.

Publish and withdraw only through the existing trusted local
`FederationService.publish/4` and `withdraw/3` APIs after host ledger/disclosure
admission. Pass `config.service` to the existing Router or `search/3` for the
combined attributed view; it carries current gossip visibility policy. A
headless gossip configuration has no RSA HTTP actor key, so the Router returns
404 for its actor document while the market HTML/JSON routes remain available. Do not
start the HTTP delivery Worker for a deployment intended to use only gossip.
Supervise the Store and gossip worker together so a failed Store restarts its
subscribers; the worker stops when its monitored Store exits. Never share keys,
journals or local business ledgers between installations.

This first adapter deliberately disables public relay services, DNS address
lookup, port mapping and automatic public infrastructure. It tests direct QUIC
with explicitly supplied addresses. NAT traversal, production relay operation,
public Internet reachability and adversarial network-load testing remain open.
Neighbor address exchange is iroh-gossip behavior: an authorized neighbor can
introduce further endpoint candidates for outbound QUIC attempts. The incoming
allowlist is **not** a complete outbound firewall. Isolate network egress as
appropriate; arbitrary HTTP fetching is not provided by this sidecar.

## Recovery and limits

Gossip broadcast is best effort. A `broadcast_queued` reply means the local
sidecar accepted work, **not** that another installation durably received it.
Optional signed receiver evidence is available for explicitly requested batches; it does not provide an exactly-once guarantee. Current accepted
home publications and tombstones remain in the journal and are reannounced
no more often than every 30 seconds; a new neighbor triggers a bounded early batch.
A process restart rebuilds work from durable source projections. It never
forwards a remote projection as a home-owned advertisement. Obsolete revisions
are skipped. Partitions converge after peers reconnect and current snapshots
are reannounced; there is no cross-node atomic snapshot or global total order.

- One gossip worker and one circle per discovery journal; use separate Stores
  and directories for separate circles. After an epoch change, old queued
  evidence remains scoped to its original context; publishers must issue a new
  accepted source event/revision for current-context discovery. At most 32
  publisher pins and 32 incoming endpoint IDs.
- 65,536-byte wire frames, 90,000-byte local command lines, bounded JSON depth
  and duplicate-key rejection at the application admission boundary.
- Native topic event buffer 32; up to 32 concurrent incoming handshakes with
  five-second deadlines. Partial local commands survive concurrent
  gossip-event cancellation of the input future. Unknown endpoint IDs are
  closed before gossip admission.
- At most 16 in-flight local broadcast requests, 12 advertisement broadcasts and 4 shared catch-up/freshness control broadcasts/minute per Store,
  120 incoming attempts/minute globally and 30 per origin. Rate counters reset
  on restart. Receipt hints are coalesced to one per subscriber, at most 32
  subscribers; the periodic repair pass recovers missed hints and lossy buffers.
- At most 16 inbox projections per pass; withdrawals run first. Repair chooses
  least recently announced snapshots, with new withdrawals before new ads.
  Moderation hides results and stops advertisements. The host rechecks current
  source/moderation before queueing a broadcast. An already queued transmission
  can finish after policy changes. A public listing withdrawal bypasses its
  local listing block. Publisher/hostname blocks still refuse incoming events.
- Existing 64 MiB fail-closed journal limit; 10,000 gossip inbox receipts and
  10,000 distinct topic/activity send timestamps. No replay/tombstone eviction.

Repeated same-ID events do not renew freshness. An advertisement becomes
visibly stale after an hour unless a new accepted revision or matching explicit
publisher freshness lease applies. The HTTP refresh path
explicitly excludes gossip projections and cannot renew their freshness from
a metadata URL, even in a host running both transports. Anti-entropy is a
bounded reannouncement of current snapshots, not a durable cursor protocol.
Explicit bounded catch-up receipts are described below. At scale, compaction,
replay-evidence backup and broader rate-fairness acceptance require further work. Deleting a journal destroys its replay evidence
and is not routine maintenance. Losing home source history requires restoration
from the host's own trusted authority.

## Bounded catch-up completion

The host can request `FederationService.GossipSync.start_round(config,
receiver_actor, activity_ids)` for 1–16 distinct current home advertisements or
tombstones. `status(config, round)` distinguishes pending, expired,
superseded and complete, with signed receiver evidence on completion.
The worker sends the committed offer as an event; the receiver signs only
after all listed content has been durably projected. A queued local broadcast
cannot complete the round. Both sides repair lost control frames after
restart without renewing advertisement freshness.

Completion concerns the exact offered batch and a named receiver journal.
It does not establish that the entire remote market is current, that a
receiver is honest, or that it still holds the data after journal loss. New
journals require new rounds. Periodic advertisement/tombstone repair continues
regardless of receipts. Each journal retains at most 128 rounds in each
direction and fails closed at capacity. The one-hour expiry and fixed send
budgets bound work without promising a completion deadline.

Exact wire/signature rules, API behavior, authority boundaries and tests:
[catch-up receipt contract](../../docs/architecture/2026-10-25-gossip-catchup-receipts.md).

## Explicit freshness renewal

A trusted host can explicitly reaffirm a still-permitted current advertisement
with `FederationService.GossipLease.renew(config, activity_id, ttl_seconds)`.
TTL is 1–3,600 seconds. A signed absolute expiry, exact content binding and
durable sequence prevent replays from extending an accepted lease. Repair
resends an existing assertion and never renews it automatically.

Search shows `freshness_source` (`projection`, `publisher_lease` or `none`) and
`freshness_expires_at`. Matching lease expiry overrides the first-receipt grace;
new revisions and withdrawals cannot inherit a previous activity's lease.
The default legacy first-receipt grace still exists for advertisements without
a matching lease, including after complete journal loss. Set
`require_freshness_lease: true` in `Gossip.config!/2` to keep remote gossip
listings stale until a matching valid lease arrives. Such unleased results have
source `none` and a null expiry; replaying an old advertisement cannot grant
freshness on first contact. Local and HTTP projections retain their policy.
The host must check current publication/disclosure permission before renewing.

Lease and catch-up frames share the existing control budget. Exact wire,
clock, replay and storage rules:
[freshness lease contract](../../docs/architecture/2026-10-25-gossip-freshness-leases.md).

## Candidate envelope v1

UTF-8 JSON, with exactly these fields:

| Field | Value |
| --- | --- |
| `schema` | `bizkit.marketplace.halaqa-gossip.v1` |
| `halaqa_id` | 1–128 ASCII letters, digits, dot, underscore or hyphen |
| `charter_hash` | 64 lowercase hex characters; context identifier only |
| `epoch` | Integer in 0..2^53−1 |
| `publisher` | 32-byte Ed25519 public key in lowercase hex |
| `announcement` | Fresh 16-byte random nonce in lowercase hex for each broadcast |
| `payload` | Standard padded base64 of JSON with exactly `activity` and `metadata` |
| `signature` | Standard padded base64 of a 64-byte Ed25519 signature |

`activity` is the unchanged accepted public wire contract. `metadata` is its
exact listing-v1 snapshot, or null for Delete. No arbitrary command fields,
private audiences or authority assertions are accepted.

Topic ID = SHA-256 of `schema`, `halaqa_id`, `charter_hash`, decimal `epoch`,
joined by LF with no final LF. Signature bytes are that same sequence followed
by LF, `publisher`, LF, `announcement`, LF, and the exact base64 `payload` string. The restricted
scope alphabet and decimal integer serialization make the transcript
unambiguous. The receiver verifies signature bytes before decoding the payload,
then checks the actor/key pin and all accepted Marketplace origin/schema rules.
Each repair uses a fresh signed announcement nonce so iroh-gossip
message-cache deduplication cannot suppress it after a partition. Application
deduplication uses activity ID and exact activity/metadata content, ignoring
this nonce; new announcements do not renew freshness.
JSON is not a new canonical ledger format. There is no protocol negotiation;
unknown schemas/fields and scope mismatches are refused.

## Acceptance

```sh
cargo fmt --check --manifest-path native/marketplace_gossip/Cargo.toml
cargo clippy --locked --all-targets --manifest-path native/marketplace_gossip/Cargo.toml -- -D warnings
cargo test --locked --manifest-path native/marketplace_gossip/Cargo.toml
cargo build --locked --manifest-path native/marketplace_gossip/Cargo.toml
BIZKIT_GOSSIP_EXECUTABLE="$PWD/native/marketplace_gossip/target/debug/bizkit-marketplace-gossip" \
  scripts/test-federation-service.sh
```

CI builds the native binary and requires the integration test. Without that
environment variable the existing HTTP-focused local suite explicitly skips
the optional native integration test; it does not establish gossip acceptance.
The harness uses two separate BEAM processes and two real native sidecars,
independent endpoint keys/journals and real QUIC. It demonstrates two-way
attributed discovery, event-driven updates, partition/restart recovery and
withdrawal without HTTP delivery commands. Ledger sentinels remain unchanged.
Signature/scope tampering, origin substitution, stale revisions, durable replay,
key revocation, moderation and cross-transport activity-ID refusal have focused
adversarial regressions. This is not an independent security audit or proof of
full Halaqa/SANAD+, Fediverse or Mastodon compatibility.

Dependency scan: cargo-audit 0.22.2 against RustSec database
`21d909e4c8bd4e14c7aea58bf980c881a0053ab1` reported no known vulnerability
advisories for the 366 locked dependencies. It reported the maintenance warning
[RUSTSEC-2024-0436](https://rustsec.org/advisories/RUSTSEC-2024-0436) for
`paste` 1.0.15, a build-time procedural macro through iroh → netwatch →
netlink-packet-core. That warning is recorded, not a proof of security or a
reason to silently replace the pinned transport's dependency graph.
