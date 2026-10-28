# Native authority for subscription control (#153)

This slice adds an opt-in signed CoopSubstrate authority adapter for the
existing operational subscription outbox. It does not close #153 or enable
public federation. Exact-head hosted acceptance is required before merge.

## Signed authority

`FederationSubscriptionGrantedV1` is a canonical governance-signed ledger
event. It requires an already declared, current governance key in its chapter;
the bootstrap rule that otherwise permits undeclared role keys cannot grant
subscription authority. Its signed event ID is the receipt retained in the
discovery journal. The payload binds exactly:

- `local_actor`, `follow_id` and `activity_id`;
- one `operation`: `accept`, `reject` or `undo`;
- the sole scope `public_subscription_control`;
- `not_before` and exclusive `expires_at`, in Unix seconds.

The envelope binds chapter, signing identity and all payload fields. Use
`FederationService.subscription_activity_id(config, operation, source_id)`
to obtain the activity ID before signing the grant. An admitted grant does not
execute anything. It cannot grant principals, memberships, commerce roles,
listing publication, private disclosure, stock reservations or payments.

`FederationSubscriptionRevokedV1` names `grant_event_id` in the same chapter
and requires current declared governance authority. Revocation is terminal.
Revoking the issuer's governance key also terminally invalidates its grants;
redeclaring the same key never resurrects them. Log replay reconstructs both
grant and revocation state. Grant envelopes are reverified at execution, and
their signer must still be declared.

## Host composition

Configure the standalone node and any host-only API caller with the same port:

```elixir
authority = CoopSubstrate.FederationAuthority.port(
  chapter_id: chapter_id,
  local_actor: local_actor,
  connection: ledger_fence_connection,
  schema: "public"
)

# Additional existing TLS, actor, peer, signing key and store options omitted.
config = FederationService.config!(Keyword.put(node_options, :subscription_authority, authority))
```

`ledger_fence_connection` is a trusted host-owned Postgrex connection or pool
to the canonical EventStore database, with access to its `streams`,
`stream_events` and `events` tables. Its schema is pinned by host configuration,
never selected by an HTTP message. Do not hand the connection, governance
signing key or port to federation request handlers or remote callers.
There is no new HTTP administrative route. The service's production dependency
graph still excludes CoopSubstrate; the adapter lives in CoopSubstrate and is
supplied explicitly by the host. The reverse dependency exists only in tests.

After the signed grant is admitted through `CoopSubstrate.Log.append/1`, call
`respond_follow` or `undo_follow` with the grant's event ID as receipt and the
exact bound source ID. Local Follow initiation remains a trusted host action;
it is not a new remotely callable or automatically authorized command.

The legacy `approval_verifier` remains available for the explicit-peer pilot.
It now runs again before control delivery, but it does not implement this
native fence. A configured native port always takes precedence; refusal,
exception, unavailable ledger or wrong receipt never falls back to that
callback. Historical opaque receipts do not become native grants on upgrade.

## Execution and revocation order

Both local journal admission and each Accept/Reject/Undo HTTPS POST execute
through the canonical appender. `FederationFence` takes `FOR UPDATE NOWAIT` on
the EventStore `ledger` stream row, which EventStore updates transactionally
on every canonical append. Under that lock it compares **both** stream version
and SHA-256 of the stored canonical head bytes to the appender's current head.
A stale appender, wrong database, busy row or unavailable database refuses the
effect. It then checks the exact grant against current signed state and the
host's current clock. A caller-supplied queue timestamp cannot extend authority.

The lock spans the synchronous journal commit or bounded HTTPS POST. Network
discovery and signing happen before taking the delivery fence. Peer policy,
moderation and exact outbox correlation are checked again inside the effect.
Authority refusal leaves pending work and its network attempt count unchanged.
Every retry requires a fresh fence, including after either journal or appender
restart. A 200/202 receipt records delivery; it never proves local authority.

An effect that enters first may complete before a queued revocation commits.
A revocation that commits first prevents the next effect. A request already
started, including one whose sender crashes or loses its database connection,
may still be observed remotely after revocation. This is a local authorization
ordering contract, not cancellation of bytes in flight or remote exactly-once
execution. No network-wide atomic transaction is claimed.

The appender and database stream lock are occupied during the effect. A slow
disk sync or stalled journal can delay unrelated ledger writes. Admission
waits for the actual journal reply rather than releasing authority on a
GenServer call timeout while an already-enqueued operation could still commit.
Use only the supplied synchronous service operations; effects must not call
back into Log, recursively acquire the fence, spawn deferred work, or retain
the effect closure. The HTTPS transport retains its five-second outer bound.
Host connection supervision and database availability are operational duties.

## Acceptance

`scripts/test-federation-authority.sh` builds an isolated host using the shared
unchanged lock, then runs native grant/fence tests plus canonical Log and
role-key regression tests against a disposable PostgreSQL database. It is a
blocking job in Federation discovery and checks out the exact PR head.
The tests cover signature/scope/field substitution, current validity,
undeclared governance, issuer revocation/redeclaration, grant revocation,
stale appenders, an independent SQL session competing for the locked row,
ordered effect/revocation, journal recovery, Reject/Undo and real signed TLS
delivery with a valid and a revoked native grant. Existing separate-process
TLS, transport, replay and listener tests continue unchanged.

The local isolated service run passed **107 tests, zero failures, two optional
skips**. The new native modules compile with the actual pinned dependencies
and canonical Rust NIF. Native PostgreSQL/TLS acceptance and the exact-head
hosted workflows are pending; local compilation is not acceptance evidence
for the database fence. No merge or deployment is claimed here.

## Still open

Accepted-subscription public listing routing, bounded relationship collections,
publication/disclosure adapters, retention/compaction and external ActivityPub
interoperability remain separate gates. An operational `accepted` relationship
is not a current authorization or permission to publish business data.
The existing full-lock security audit remains blocking without advisory
exceptions; this slice does not change the lock or replace that audit.
