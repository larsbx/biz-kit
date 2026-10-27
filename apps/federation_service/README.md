# Read-only marketplace discovery

`federation_service` adds an explicitly started HTTPS service around
`FederationCore.Marketplace`. It reuses the listing v1 schema and origin rules
merged in [PR #114](https://github.com/larsbx/biz-kit/pull/114). It is a bounded,
explicit-peering pilot, not a general Fediverse server or a commerce authority.

For event-driven P2P delivery over iroh-gossip, see the
[experimental Halaqa-scoped adapter](../../native/marketplace_gossip/README.md).
It reuses the accepted activities and metadata, with explicit publisher key
pins and durable scoped inbox projections. Its topic transport does not use
HTTP delivery peering or Follow/Accept polling.

## What runs

- Public Service actors with an RSA public key, inbox and paged outbox.
- Optional exact-account WebFinger discovery using a deliberately configured
  public handle, with no login, following, subscription or grant implications.
- HTTPS actor discovery, current actor/key ownership validation and RSA-SHA256
  HTTP request signatures covering `(request-target) host date digest content-type`.
- Authenticated inbox entries journaled and synced before HTTP 202. A worker
  fetches owner-origin metadata and commits deduplication/projection changes
  together. Transient fetch failures remain queued with exponential backoff.
- Durable local public projections and per-peer delivery work with stable
  source-event/activity IDs. At most 32 explicitly configured remote actors;
  no recursive actor, audience, follower or relay expansion.
- Revision-monotone remote projections, immutable seller ownership, durable
  moderation and terminal withdrawals. Delete-before-Create is safe. The v1
  Delete schema has no revision, so a withdrawn ID is never resurrected: use
  a new listing ID to republish.
- `/market` and `/market.json` combine local and remote advertisements. Both
  accept a bounded `q` search parameter. Every result identifies its source,
  seller actor, revision, verification time and stale status. Text is escaped;
  remote HTML, scripts and images are not rendered.

All HTTP routes are public discovery routes except the authenticated inbox.
There is **no** HTTP publication, command, ledger, reservation or payment API.
The app depends on federation_core, Plug, Jason and Bandit; it does not depend
on any business command dispatcher, principal registry or signed ledger app.

## Start an installation

Use Elixir 1.19 / OTP 27, Linux with `flock` (util-linux), a local persistent
filesystem, a stable public HTTPS origin and independently managed keys. Do
not share a journal directory, private key or business ledger between nodes.
`flock` refuses a second process using the same journal directory and releases
ownership when its owner exits. The discovery directory is restricted to 0700.

Generate a dedicated HTTP signing key, distinct from the TLS private key:

```sh
umask 077
openssl genrsa -traditional -out marketplace-signing.pem 3072
```

Add this explicit child to an appropriately configured host supervisor:

```elixir
{FederationService.Node,
 actor: "https://alpha.example/actors/shop",
 handle: "shop",
 peers: ["https://beta.example/actors/shop"],
 signing_keyfile: "/run/keys/marketplace-signing.pem",
 directory: "/var/lib/biz-kit/marketplace-discovery",
 certfile: "/run/keys/tls-chain.pem",
 keyfile: "/run/keys/tls-private.pem",
 port: 8443}
```

The default listener is loopback HTTPS on 8443. Route public port 443 to it and
preserve the exact canonical Host header. Do not use forwarded headers to
change the signing target. The production fetcher accepts only public HTTPS
port 443; arbitrary alternate ports and private peering addresses are refused.
Each peer configures the other's actor URL independently. No passwords,
principal grants, local ledger keys or commerce rights are exchanged.

The supervisor starts the journal, bounded HTTP listener and serial worker.
It restarts them together, retaining the journal and resolving the same store
name. Nothing automatically enables this service in existing biz-kit releases.
The test harness alone disables background work so fault ordering is exact.

## Authorized local publication

A host integrates publication **after** its own signed ledger accepts an
owner-authorized publication event and its disclosure/consent policy permits
all fields. Pass the exact public projection and stable source event ID to:

```elixir
config = FederationService.config!(
  actor: "https://alpha.example/actors/shop",
  peers: ["https://beta.example/actors/shop"],
  private_key: FederationService.Signature.private!("/run/keys/marketplace-signing.pem"),
  store: FederationService.Store)

{:ok, public} = FederationCore.Marketplace.metadata(%{
  seller_actor: config.actor,
  listing_id: "https://alpha.example/listings/part-42",
  revision: 0,
  title: "Replacement part",
  summary: "Public advertisement; confirm availability with the seller.",
  category: "parts",
  price: %{currency: "USD", minor_units: 1250}
})

FederationService.publish(config, "accepted-source-event-id", public, :create)
# Later: a higher revision and new source event ID, with kind :update.
FederationService.withdraw(config, "accepted-withdrawal-event-id", public["id"])
```

This host-only API is the local publication trust boundary. It does **not**
verify a source ledger event or grant by itself. The pilot supplies the service
and integration interface, not a production adapter for every biz-kit domain's
ledger/disclosure policy. Never connect untrusted request data directly to it.
Repeated source events are idempotent; a changed payload under the same event
ID is refused. The source-event fingerprint excludes peer configuration: changing
or reordering peers does not invalidate a receipt. Before each delivery pass,
the worker reconciles configured peers against already accepted local public
projections. A newly configured peer receives each listing's current activity,
including terminal withdrawals, without creating a new source event or
replaying obsolete revisions.
Publication and all peer delivery rows commit together. Network
failure cannot undo local business history or create another business writer.

## Peer reconciliation and queue recovery

Changing `peers` in the local node configuration and restarting the node is an
explicit local peering decision. The worker backfills current public listings
and tombstones to those peers in batches of at most 32 journal changes. It uses
the original accepted activity IDs and the current publication per listing;
a peer can receive an Update snapshot before ever seeing its original Create.
Remote projections are never forwarded as home-owned listings.

Reconciliation is also available through the trusted local host API, with no
new HTTP administration endpoint:

```elixir
{:ok, stats} = FederationService.reconcile(config)
# inserted, held, resumed, superseded, settled, requeued: changes in this batch
# more: further reconciliation is needed; capacity: outbox capacity prevented insertion
```

The worker repeats batches, including after restart. Repeating a completed
batch does not write another journal transaction or duplicate delivery rows.
Late in-flight acknowledgments are retained, including when policy is holding
the activity. If policy later permits it, that receipt settles the row without
another POST (`settled` in the batch statistics). Failed duplicate attempts
cannot erase the first acknowledgment. Existing successful delivery receipts
are not reset when a
peer is removed/re-added. This is bootstrap for a newly peered installation,
not automatic repair of a remote installation that has deliberately discarded
its own acknowledged cache. Recovery from that loss requires the explicit local
redelivery operation described below.

| Current condition | Queue behavior |
| --- | --- |
| Latest public activity, configured and unblocked peer | Pending delivery |
| Peer removed or blocked, or local listing moderated | Held without retry churn |
| Policy permits a held current activity again | Resume immediately |
| A newer revision or withdrawal replaces unsent work | Superseded; no further transmission |
| Peer acknowledged an activity | Receipt retained; no automatic resend |

The sender checks source identity, current activity and moderation both before
actor discovery and immediately before starting the POST. An already started
request may still finish after a policy/source change. Its receipt is recorded
without changing held or superseded work back into pending work. Withdrawals
are prioritized before reconciliation batch/capacity truncation and before
network transmission and bypass a local listing block, while
peer/hostname blocks still prevent all contact with that peer. At most 16
ready activities are sent per delivery pass.

The finite 10,000-row outbox limit still applies. Reconciliation reports
`capacity: true` and retains evidence rather than evicting delivered receipts,
source events or tombstones. It does not solve journal compaction or large-scale
retention. Delayed inbox advertisements covered by an existing terminal
withdrawal are rejected locally without repeatedly fetching unavailable terms.

## Explicit peer cache recovery

After independently confirming that an already configured peer needs its current
public advertisements again, a **trusted local sender administrator** can request:

```elixir
{:ok, generation} = FederationService.redeliver(config, "https://beta.example/actors/shop")
```

This journals a new per-peer delivery generation before returning. Each call is
an explicit new resend request; it is not an idempotent source event. The worker
requeues only current home publications and terminal tombstones, at most 32
journal changes per reconciliation pass and 16 POSTs per delivery pass, with
withdrawals first. Activity IDs, source-event receipts, public metadata and local
business history stay unchanged. Other peers' delivery receipts are unaffected.
The command has no HTTP endpoint and cannot be requested by a foreign activity.
It refuses unconfigured or blocked peers, respects listing moderation, and
never forwards remote projections. Existing rows are reused at outbox capacity;
missing rows still require capacity. No replay evidence is evicted.

The request and partially processed batches survive restarts and temporary
partitions. Acknowledgments are scoped to the generation sent: an old in-flight
success or failure cannot finish or reschedule the new generation, even before
its row has been requeued. The first acknowledgment time is retained alongside
the latest acknowledged generation/time. Legacy rows without generation fields
are interpreted as generation zero. Repeated redelivery to a healthy receiver
uses its normal activity-ID/body deduplication, without renewing freshness.
At most 10,000 distinct repair destinations can be journaled over a store's
lifetime; the finite journal size also still applies.

This is an operator-driven recovery tool using the existing signed wire profile,
not a new remote reset protocol or a consistent cross-node snapshot. Concurrent
publications continue to replace older work. An administrator must coordinate
recovery with the peer and inspect the results; no remote completion attestation
is implied by HTTP receipt. Redelivery does not reconstruct lost inbox history,
moderation policy or a home publication ledger. Never delete a discovery journal
as routine maintenance: losing it also loses its replay evidence, tombstones,
blocks and local publication/delivery receipts. Restore those from trusted
backups or the host's own authority before admitting traffic after such a loss.

## Security and recovery profile

The fetcher resolves A/AAAA addresses once, refuses mixed public/private answer
sets and connects directly to a vetted IP tuple. TLS chain and hostname checks
use the original hostname. It never re-resolves at connection time and never
uses a proxy, redirect, compression or JSON-LD context expansion. DNS and the
entire request execute within a five-second killable process. Connect/read
operations also have two-second deadlines. Only native global IPv6 unicast is
eligible; transition/reserved/documentation ranges are refused conservatively.

Responses require Content-Length, at most 65,536 body bytes, at most 40 headers
and 16 KiB of total response headers. Chunked/compressed responses are refused.
JSON has at most 16 structural levels and rejects duplicate object keys. Only
plain application/json or application/activity+json documents are decoded.

Requests require exact Host, route, content type, body digest, covered headers,
RSA key ID and current HTTPS actor/key association. RSA keys must have 2048–4096
bits and exponent 65537. Dates must be within 300 seconds. Signature algorithm
negotiation, arbitrary key-URL fetches, delegated keys and actor migrations are
not supported. Every request refetches the actor document: removal of the key,
actor unavailability or a changed key fails closed. An old key is not retained
as a fallback. Rotate the local signing file by restarting the node; peers
learn the replacement from the current HTTPS actor document.

Before discovery fetches, global and per-actor inbox rate limits and explicit
peer policy apply. Inbox limits are 120 requests/minute globally and 30 per
actor; all HTTP routes share 600/minute. These are in-memory availability
controls and reset on restart. Durable activity IDs, owner bindings and
withdrawals survive restarts. Deploy ingress connection/traffic controls too;
these bounded application controls are not a distributed denial-of-service
service. The listener caps headers, idle reads and concurrent connections and
serves HTTP/1.1 only.

Administrators use the **local** store API for actor, hostname or listing
moderation. Blocking immediately hides existing results and rechecks pending
admission/projection/delivery; unblocking is explicit. Listing blocks hold
pending Create/Update deliveries while allowing that listing's withdrawal. This is not a public
moderation endpoint:

```elixir
FederationService.Store.call(FederationService.Store,
  {:block, "beta.example", true})
```

Metadata refresh runs at most four known listings per tick and no more often
than every 15 minutes per listing. Only an identical owner-origin snapshot
renews verification time; changed terms need a signed Update. Failed refreshes
leave the old timestamp. Duplicate activities and stale revisions cannot renew
freshness. Listings become visibly stale after one hour; stale listings remain
advertisements, with no availability or transaction authority implied.

Each journal transaction is one `disk_log` record, synced before acknowledgment.
The OS-process harness exercises restart after an accepted inbox receipt and
restart with pending delivery. The journal is a recoverable discovery cache,
not a signed business ledger, replicated database or claim of exactly-once
network delivery. Its single-writer local-filesystem assumption is explicit;
NFS/multiwriter deployments are unsupported. The journal stops at 64 MiB or
10,000 accepted source events / inbox entries / delivery rows. Capacity errors
fail closed. No replay evidence or tombstone is silently evicted; monitor disk
usage. Compaction/retention and large-scale operation require further work.

## Reproduce acceptance

From the repository root:

```sh
scripts/test-federation-service.sh
```

This stages only federation_core/service with the existing dependency pins,
compiles with warnings as errors, checks formatting and runs all focused tests.
The integration harness creates temporary CA/TLS and RSA signing keys and starts
**two separate BEAM OS processes**, with independent keys and journal directories.
It uses real TLS, raw signed HTTP requests and the actual Node supervisor/router.
A compile-time test-only connector maps the two example domains to loopback;
production builds refuse this override. No fixture private keys are committed.

The stdin control channel exists only in `test/support/node.exs`; it is not an
HTTP API or a production control interface. Tests control worker steps to put
failures precisely between durable receipt, projection and delivery.

Evidence covers two-way discovery, updates, duplicate receipts, ownership/origin
substitution, body/target/key tampering, certificate/hostname refusal, rotation,
moderation, bounded/hostile HTTP responses, pagination, markup escaping, restart
and partition recovery, late-peer bootstrap, bounded reconciliation, withdrawal
priority, paused/resumed/superseded delivery, explicit cache-loss redelivery,
generation-scoped acknowledgments, terminal withdrawals and negative
business endpoints.
The harness also checks an independent local-ledger sentinel remains unchanged.
It does not load or prove every biz-kit ledger implementation: authority isolation
also follows from the service's absence of business-app dependencies/callbacks.

## Interoperability limits

This is a same-implementation two-node test, **not independently demonstrated
Mastodon/Fediverse interoperability or full ActivityPub conformance**. The profile
supports only explicit public Service peers and Create/Update/Delete listing v1
messages. It uses a deliberately strict legacy RSA HTTP-Signature syntax, not
RFC 9421 negotiation. It does not implement WebFinger, Follow/Accept/Undo,
relay discovery, authenticated GETs, private audiences, actor moves, key caches,
foreign actor types, third-party JSON-LD contexts or cross-node commerce.
Outbox pages are bounded at 20 activities, ordered deterministically by activity
ID; concurrent publication may change page membership. They are diagnostic
public collections, not a durable synchronization cursor. Durable per-peer
push delivery is the recovery path in this pilot. Nodes returning compressed
or chunked documents need an adapter or further transport work.

Payment, settlement, stock holds, inventory reservations, contract acceptance,
verified reputation and private learner/employee/buyer data remain outside this
milestone. Issue [#115](https://github.com/larsbx/biz-kit/issues/115) stays open for
its broader subscription, disclosure-adapter, scale and interoperability gates.


## Durable subscription-correlation pilot

`FederationService.SubscriptionState` provides deterministic, replay-safe
journal planning for *trusted host* Follow initiation, authenticated inbound
Follow/Accept/Reject/Undo candidates, explicit local approvals/rejections,
and subscriber-origin withdrawals. Accepted plans commit atomically through
the existing discovery journal; duplicates and invalid transitions do not
write and terminal requests never reactivate. Authority receipts are opaque
references **supplied by a trusted host**: this library does NOT validate
that an operator actually holds a grant or verify an HTTP signature.

Use `FederationService.Store.call(store, {:subscription, intent})` only from
an adapter that has already checked signer identity, peer policy and local
authority. There is no public subscription HTTP route, signed subscription
delivery worker, dynamic peers, follower collection, or merchant permission
derivable from these rows. They are operational correlation state, never
business events. A future host adapter must implement authentication,
authority rechecks, bounded queued deliveries and restoration tests before
claiming working ActivityPub following. Current inbox still handles only
public listing events.

## Authenticated inbound subscription admission

The signed HTTPS inbox can now record narrow Follow/Accept/Reject/Undo messages
from **explicitly configured peers only**. Each message must pass current
remote-actor signature validation, the peer allowlist, exact wire shape and
local moderation before a durable subscription-journal transition. No remote
message grants local business authority; Follow stays pending until a trusted
local host explicitly approves it. Retransmission and restart safety are
covered by the two-node TLS harness.

There is no dynamic peer admission, public approval API, follower collection,
locally authorized reply delivery, private offer exposure or cross-node
commercial write. Keep this pilot behind existing explicit peering and do not
claim general Mastodon interoperability or production deployment.

## Signed outbound subscription-control pilot (October 2026)

The trusted in-process `FederationService.follow/3`,
`respond_follow/5`, and `undo_follow/4` functions now stage
a signed `Follow`, `Accept`/`Reject`, or `Undo` activity into
`subscription_outbox` **in the same durable journal transaction**
as its corresponding request/decision/replay receipt. No external
admin HTTP route is created. `deliver_subscriptions/1` signs each
bounded outgoing delivery with the node's existing RSA key, checks
explicit peer policy immediately before posting, and retries after
crashes or partitions. Confirmed HTTP 200/202 responses durably
settle effects, while unsuccessful attempts are backed off.

The journal only checks that an opaque, nonempty local authority
reference was supplied. It does **not** verify a ledger grant or
signature. Integration callers MUST independently authenticate the
instruction and validate the approval's signed ledger authorization
before calling these host-only functions. The standalone integration
harness uses a synthetic receipt, which has no production authority.
This does not enable arbitrary remote peer discovery or private
business data distribution; only the configured public control
activities flow. It is not generic Fediverse conformance.

### Local authority verifier boundary

`config!(approval_verifier: fn local_actor, follow_id, operation, receipt, now ->
  ... end)` is **mandatory** for `respond_follow` and `undo_follow`.
No verifier means *fail closed*. The verifier must validate an independently
admitted local governance grant, signing key, time validity and operation
scope against the current authoritative ledger; only literal `:ok` is accepted.
It is invoked before journal admission, so revocations racing the external
ledger's admission fence still require an integration-level atomicity/fencing
contract. The test harness intentionally uses a synthetic hardcoded receipt,
not a production credential or proof of business authorization.
