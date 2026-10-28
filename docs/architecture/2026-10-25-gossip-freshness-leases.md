# Explicit signed freshness leases for marketplace gossip

## Meaning and host API

A discovery publisher can reaffirm an unchanged, currently permitted public
advertisement without inventing a new business event or listing revision:

```elixir
{:ok, assertion} = FederationService.GossipLease.renew(config, activity_id, 3600)
```

`config` is the existing Gossip configuration with its independently held
endpoint signing seed. The optional TTL is an integer from 1 to 3,600 seconds.
The return value is the committed assertion; actual signing/transmission is
performed by the event-driven worker. The trusted host must explicitly
revalidate its current publication/disclosure permission and intention before
calling this API. Merely possessing a cached listing is not authorization to
renew it. Periodic repair, receipt handling and worker restart never issue a
new lease automatically.

The assertion applies only to the exact current local activity and canonical
activity/metadata content hash. Withdrawn, blocked, superseded, missing or
unsupported-content publications refuse. Issuance and the increasing sequence
are committed and synced together before notifying the worker. No signed
business-ledger event, metadata revision or inventory fact is manufactured.

## Experimental wire profile

Schema: `bizkit.marketplace.halaqa-freshness.v1`. Messages use the existing
scoped gossip topic and have exactly the following fields:

| Field | Value |
| --- | --- |
| `schema` | Exact profile string above |
| `halaqa_id`, `charter_hash`, `epoch` | Exact current configured scope |
| `actor`, `publisher` | Pinned actor URL and lowercase hex Ed25519 key |
| `listing_id`, `activity_id` | Exact listing and applied activity IDs |
| `hash` | Canonical SHA-256 content hash from the catch-up profile |
| `sequence` | Integer in 1..2^53−1, increasing per scope/key/listing |
| `issued`, `expires` | Absolute integer Unix seconds, expiry minus issue in 1..3,600 |
| `announcement` | Fresh random 16-byte lowercase hex nonce per transmission |
| `signature` | Standard padded base64 Ed25519 signature |

Ed25519 signs the complete message with only `signature` removed, using
`GossipSync.canonical/1` and its restricted JSON subset. The schema provides
domain separation from advertisements and catch-up messages. The content hash
and canonical string rules are defined in the
[catch-up contract](2026-10-25-gossip-catchup-receipts.md).

A receiver verifies exact shape, signature, scope and current actor/key pin.
Sequence and time values are bounded integers. Expired leases, lifetimes over
one hour and issue times more than 30 seconds in the future refuse. A lease
accepted within that clock tolerance is still stale before its signed issue
time. Signature, listing, activity and content must all match the **current
applied gossip projection**. HTTP-only, pending, rejected, conflicting,
withdrawn or superseded evidence cannot be renewed. An early lease is refused
until its advertisement is projected; periodic retransmission can repair that
ordering without a separate unbounded pending queue.

## Freshness, replay and recovery

The receiver durably retains the latest lease and original signed message,
indexed by topic/key/listing. Higher sequences replace lower ones only when
issue time does not move backward. Same-sequence changed assertions conflict;
exact duplicates preserve the existing record. Older sequences refuse even
when they would provide a later expiry. These high-water marks survive restart
and metadata revision changes. Expiry does not evict replay evidence.

Search exposes `freshness_source` and `freshness_expires_at` alongside the
existing `stale` flag. A matching lease uses the half-open interval
`issued ≤ now < expires`; it overrides the original receipt-based grace even
when it shortens that grace. An expired lease therefore cannot be converted
into new freshness by duplicate announcements, receipt replay, restart or an
HTTP metadata fetch. The underlying `verified_at`, metadata, revision, source
events and projections remain unchanged. A newer listing revision starts with
its own projection freshness and cannot inherit an old activity's lease.

By default, advertisements without a matching lease retain the existing
one-hour first-projection/HTTP-refresh policy, including on first contact with
an old advertisement or after complete receiver-journal loss. The opt-in
acceptance policy below removes that grace for remote gossip results. A lease
establishes the publisher's bounded freshness assertion, not physical stock,
current custody, honesty or permission to transact.

### Require a lease on remote gossip results

A receiver can remove that first-receipt grace locally without changing the
wire profile or requiring every peer to upgrade:

```elixir
config = FederationService.Gossip.config!(service,
  scope: scope,
  seed: endpoint_seed,
  publisher_keys: pinned_keys,
  require_freshness_lease: true)
```

The option is a validated boolean and defaults to `false` for compatibility.
It must be supplied again when configuring a restarted host. It does not change
topic identity, signed messages, journal data or admission of advertisements.
Under this policy a remote gossip projection without a matching lease is
visible with `stale: true`, `freshness_source: "none"` and
`freshness_expires_at: nil`, even on first contact or after complete cache loss.
A captured expired lease refuses; a new announcement, catch-up receipt or
restart cannot make the advertisement fresh. Every new revision needs its own
matching lease. Once a lease is known, its signed interval governs freshness as
above. A captured, still-valid signed lease can establish freshness only until
its original expiry; freshness does not establish when it was received.

This policy applies only to remote gossip projections. Local publications and
HTTP projections keep their existing freshness policy. Peers that never issue
leases remain discoverable but stale. Unsupported canonical content cannot be
leased and therefore remains stale under this policy. All nodes still need
trusted clocks, current key pins and retained tombstone/replay history; lease
requirements do not recover a lost withdrawal or prevent an old revision from
being displayed as a stale advertisement after complete journal loss.

Local sequence and issue-time history also survive restart. Backward local
clocks refuse renewal. Restoring an older publisher journal can lose sequence
progress: receivers fail closed against their retained high-water mark. Do
not reset sequences or delete journals as routine maintenance; restore trusted
history or deliberately review a new key/scope transition. Wall-clock trust,
key pinning and host admission remain explicit assumptions.

## Bounds and transport

Latest local and remote lease maps each permit at most 10,000 topic/key/listing
records. Updates replace those in-memory entries; the append-only journal
retains history and keeps its existing 64 MiB fail-closed limit. No compaction
or automatic high-water-mark eviction is added.

At most four lease frames are prepared per worker pass. Lease and catch-up
control traffic share the existing four-broadcast/minute budget, selected by
least-recent send time across both classes. Advertisements retain their
separate twelve-broadcast/minute budget and sixteen total in-flight requests.
Incoming messages share the existing 120 global/30 per-origin minute limits.
Unexpired leases repair at most every 30 seconds with fresh announcement
nonces; expiry is never extended by repair. A stale local queue acknowledgment
cannot mark a newer lease sequence sent. Key, scope, source and moderation are
rechecked before transmission. Already queued frames can finish after a
policy change, as with the existing adapter.

## Acceptance

Focused regressions cover opt-in cold-receiver/revision freshness, policy
validation, HTTP/local isolation, exact-content renewal, fixed expiry, shortened
leases, replay/conflict/tampering, durable sender/receiver sequence recovery,
revision/withdrawal isolation, moderation/key/scope/transport refusal, bad TTL,
clock rollback and stale local queue acknowledgments. The real two-process
QUIC test requires leases, observes initial and updated remote projections as
stale, renews an unchanged listing, observes the publisher lease remotely,
restarts both nodes through a partition and confirms lease persistence without
new source events. Business-ledger sentinels remain unchanged.
