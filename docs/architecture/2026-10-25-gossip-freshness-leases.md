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

Legacy advertisements without a matching lease retain the existing one-hour
first-projection/HTTP-refresh policy. This profile does **not** eliminate the
legacy first-receipt grace after complete receiver-journal loss or first
contact with an old advertisement. Eliminating that ambiguity requires a
separately adopted timestamped advertisement profile/acceptance policy. A
lease establishes the publisher's bounded freshness assertion, not physical
stock, current custody, honesty or permission to transact.

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

Focused regressions cover exact-content renewal, fixed expiry, shortened
leases, replay/conflict/tampering, durable sender/receiver sequence recovery,
revision/withdrawal isolation, moderation/key/scope/transport refusal, bad TTL,
clock rollback and stale local queue acknowledgments. The real two-process
QUIC test renews an unchanged listing, observes the publisher lease remotely,
restarts both nodes through a partition and confirms lease persistence without
new source events. Business-ledger sentinels remain unchanged.
