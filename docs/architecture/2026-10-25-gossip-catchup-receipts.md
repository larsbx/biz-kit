# Bounded gossip catch-up and receiver evidence

## Contract

`FederationService.GossipSync` adds an explicitly requested, signed batch
completion protocol to the experimental marketplace gossip adapter. It uses the
same scoped Iroh topic and existing publisher key pins. It does not establish
Halaqa protocol adoption, membership, business authority or a global snapshot.

A host calls `GossipSync.start_round(config, receiver_actor, activity_ids)`
with **1–16 distinct current home activity IDs**, including current tombstones.
The receiver must already be pinned. The result is `{:ok, round}`. Creating the
round commits its immutable manifest before waking the gossip worker. This is
a local API, not a remotely callable business command. Larger selections need
separate explicit batches; completion of one batch says nothing about omitted
publications. Advertising and withdrawal continue through the existing APIs.

`GossipSync.status(config, round)` returns pending, expired, superseded, or
complete. Complete includes the receiver's original signed message, its local
observation time, and `current`, which checks whether every offered source is
still the current permitted home publication. Superseding a source never
rewrites a completed historical receipt. Current key/scope policy can hide a
round even when its evidence remains in the journal.

## Signed wire profile

Schema: `bizkit.marketplace.halaqa-catchup.v1`. This is a separate experimental
profile; the original advertisement schema and topic derivation are unchanged.
All messages have exactly these common fields:

| Field | Meaning |
| --- | --- |
| `schema` | Exact profile string above |
| `kind` | `offer` or `receipt` |
| `halaqa_id`, `charter_hash`, `epoch` | Exact configured topic context |
| `from`, `to` | Exact pinned source and intended recipient actor URLs |
| `publisher` | Lowercase hex Ed25519 public key of `from` |
| `round` | Fresh 16-byte round nonce in lowercase hex |
| `batch` | Lowercase hex SHA-256 manifest commitment |
| `expires` | Integer Unix seconds; fixed at creation time plus 3,600 |
| `announcement` | Fresh 16-byte hex nonce per transmission |
| `signature` | Standard padded base64 Ed25519 signature |

An offer additionally has `entries`: 1–16 objects with exactly `id` and `hash`.
IDs are distinct, at most 2,048 UTF-8 bytes, and sorted by UTF-8 byte order.
Each hash commits to `{"activity": activity, "metadata": metadata}`; a Delete
has null metadata. A receipt instead has `journal`: the receiver's random
16-byte journal identifier in hex, durably generated on first protocol use.
The receipt reverses `from` and `to`, uses the receiver's publisher key, and
retains the offer's exact round, batch, expiry and scope.

Canonical JSON for this profile recursively sorts object keys by their UTF-8
bytes, preserves array order, uses decimal integer spelling, and uses Jason
1.4.5's JSON string escaping without whitespace. The accepted subset contains
strings, integers, booleans, null, arrays and string-keyed objects; floats are
not supported. An otherwise valid advertisement can contain attachment extension
values outside this subset. Such content has no catch-up hash: a local round
is refused and a remote offer stays nonmatching, including after restart.
Ordinary advertisement admission and repair continue. This is a profile-specific format, not a claim of RFC 8785
conformance. `GossipSync.canonical/1` implements it and has a fixed test vector.

The content hash is SHA-256 of that canonical activity/metadata object. The
batch commitment is SHA-256 of the canonical offer restricted to `schema`,
`halaqa_id`, `charter_hash`, `epoch`, `from`, `to`, `publisher`, `round`, `entries`
and `expires`. Ed25519 signs the canonical complete message with only
`signature` removed. Unknown fields, duplicate JSON keys, oversize/nested
messages, invalid signatures, wrong recipient/scope/pins and expired messages
are refused. Receipt verification also requires a matching durable outgoing
round, exact batch/expiry and the original pinned receiver key. The original
local publisher key must still be current.

## Completion and recovery

An offer is journaled before processing. The receiver emits no receipt until
**all** listed activities have matching canonical content hashes in its
applied gossip inbox, with the correct original publisher, actor and scope.
Pending, rejected, blocked, HTTP-only or conflicting evidence is insufficient.
The completion marker is separately committed and synced before a receipt can
be signed. A crash after projection but before completion resumes from the
pending durable offer; a crash after completion resends the receipt. Neither
path applies a publication twice or changes listing freshness.

The sender verifies the signed receipt and syncs its original signature and
message before reporting completion. Fresh announcement nonces do not create
new rounds, rewrite stored receipts or refresh advertisements. Same-round
changed offers conflict; unknown receipts and changed completed receipts
refuse. Lost acknowledgments are repaired by bounded repeated offers and
receipts until expiry. Local `broadcast_queued` only updates send timing and
cannot complete a round.

The journal identifier survives ordinary restart. Losing/replacing a receiver
journal requires a **new explicit round** to obtain evidence from that new
journal; old receipts remain historical. A receipt is a signed statement by a
pinned receiver, not a proof that a dishonest receiver retained data, nor proof
of current possession after rollback, erasure or a subsequent crash. Do not
use it to suppress the existing periodic publication/tombstone repair.

## Bounds and authority

Each direction retains at most 128 rounds per journal, with no automatic
receipt/replay eviction. Capacity and the existing 64 MiB journal limit fail
closed. Expired rounds stay available for inspection; this slice adds no
compaction or destructive maintenance API. Completion processing handles at
most 16 ready rounds per pass; unresolved offers do not starve ready ones.
Control frame selection uses least-recent send time across both directions.

The worker permits at most 12 advertisement broadcasts and 4 shared catch-up/
freshness control broadcasts per minute, within the existing 16-request in-flight bound. A
control row is reannounced no more often than every 30 seconds, even across
restart. Incoming advertisements and controls share the existing global
120/minute and per-origin 30/minute attempt limits. Counters reset on restart;
these are workload bounds, not a distributed denial-of-service proof. There
is no unconditional completion deadline during partitions, overload, clock
skew, source changes or key/policy changes.

Foreign data remains read-only discovery. No receipt writes a signed business
ledger, authorizes payment/reservation/settlement, delegates a role or proves
charter adoption. Public relay/NAT acceptance and independent third-party
interoperability remain separate work.

## Acceptance

The focused tests exercise full and partial batches, exact signed receipt
binding, replay, restart before/after completion, unchanged freshness,
revocation/moderation/scope refusal, expiry, supersession, capacity and fairness.
The two-process QUIC test requests a round, observes completion, restarts both
independent journals through a withdrawal partition, inspects historical
completion, then requests and completes a new tombstone round. Ledger sentinels
remain unchanged. Run the existing federation discovery workflow and
`scripts/test-federation-service.sh` with the native executable enabled.
