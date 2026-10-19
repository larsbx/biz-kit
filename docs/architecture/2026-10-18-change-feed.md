# Change feed

Date: 2026-10-18. Status: **implemented** in `CoopSubstrate.Feed`,
`Feed.View`, `Feed.SSE` and `Feed.Access`; served by SpruceGoose to agents
(signed reads) and people (sessions, see [identity](2026-10-18-identity.md)). Delivery is modelled
in [`spec/change_feed.qnt`](../../apps/coop_substrate/spec/change_feed.qnt).
Serves the calendar client of
[task timing and agent suggestions](2026-10-18-task-timing-and-suggestions.md).

## Why

A calendar client needs a project's tasks, pending suggestions and delegations,
and needs them kept current: an agent's suggestion should appear as it is
made, an operator's accept as it lands. Polling the ledger would either lag or
load it. The feed pushes changes, and lets a client that drops off resume
where it stopped.

## Contract

A subscriber opens a session for one **scope** `{chapter_id, tenant_id,
project_id}` at a **cursor**, a `global_seq` (0 for everything):

```elixir
{:ok, session, frame} = Feed.open(scope, cursor)
# on {:coop_ledger, envelopes}:  {frame | nil, session} = Feed.advance(session, envelopes)
# on a heartbeat:                {frame | nil, session} = Feed.tick(session)
```

A **frame** is `%{seq: n, changes: [%{kind, id, value}]}`, where `kind` is
`:tasks`, `:suggestions`, `:delegations` or `:receipts` and `value` is the whole entity
(an upsert, never a patch). Applying a frame's changes to the client's view
as of the previous frame gives the view as of `n`, and `n` is the cursor to
resume from.

- `open/2` always returns one frame, from the cursor to the head. At cursor 0
  that frame is the project's current state, so a client needs no separate
  snapshot call. On resume it holds only what changed since the cursor, one
  entry per changed entity however many events touched it.
- Events outside the scope move the session's cursor but send no frame.
- A cursor beyond the head is refused (`:cursor_ahead`): the client's state
  came from another ledger, and it must start again from 0.

The feed sends server state, not ledger events. Clients never fold events,
so the admission rules stay in one place.

## What a client sees

`Feed.View` whitelists fields and makes them JSON-safe (byte strings become
lowercase hex):

| Kind | Fields |
| --- | --- |
| task | `state`, `version`, `title`, `description`, `definition_of_done`, `timing`, `timing_version`, `timing_delegation_id`, `last_event_id`, `started_by` (once started), `cancellation` (once cancelled: event ID, principal or none for governance, reason), `dod`, `readiness` |
| `readiness` | `event_id`, `artifact_requirements` (name → digest), `predecessor_ids`, `sop_digest`; `acknowledgment` as principal, key ID and custody receipt ID |
| `dod` | `event_id`, `criteria`, `definition_ref`; `submission` and `review` as event and principal IDs, `review.submission_event_id`, `review.decision` and `review.reason` |
| suggestion | `task_id`, `kind`, `change`, `principal_id`, `base_timing_version`, `rationale`, `rationale_receipt_id`, `status`, `reason`, `reason_receipt_id`, `resolved_by_event_id` |
| delegation | `delegator_principal_id`, `operator_grant_id`, `principal_id`, `key_id`, `kinds`, `task_ids`, `states`, `window`, `max_block_ms`, `budget`, `used`, `active`, `delegator_grant_active` |
| receipt | `digest`, `principal_id` (a custody receipt in the project; [lifecycle](2026-10-19-lifecycle.md)) |

Public keys and DoD evidence stay out. `delegator_grant_active` is derived:
revoking an operator's grant ends their delegations without touching the
delegation records, and the derived field is what carries that to clients.

## Delivery

`Log.append/2` persists a batch, then, in the same call, sends
`{:coop_ledger, envelopes}` to every process registered in
`CoopSubstrate.Feed.Registry`. A subscriber can register between those two
steps, so the session must handle overlap and loss:

1. `open/2` **registers before it reads** the store. An append is then read,
   notified, or both, never neither.
2. `advance/2` drops envelopes at or below the cursor and folds the rest. If
   they skip ahead of the cursor, it **backfills from the store** instead.
3. `tick/1` asks the appender for its head and backfills if the session is
   behind. That covers a notification lost when the appender dies between
   persisting and notifying, with nothing appended afterwards.

One session per process: notifications go to the process.

### Model

`spec/change_feed.qnt` models one subscriber against the appender, with
persisting and notifying as separate steps, lost notifications, and both
orders of register and read. `safety`:

- **in order:** the client receives events 1, 2, … each once, without gaps;
- **within the store:** never past what is persisted;
- **lossless:** registering first, once notifications drain, the client has
  every persisted event (unless one was lost, which `tick` repairs).

Four witnesses are reachable: reading before registering loses an event for
good; a lost notification leaves the client behind; catch-up and
notifications overlap; a gap reaches the consumer. Safety holds over 3,000
sampled runs and exhaustively to depth 10. A consumer that appends whatever
arrives, without the cursor check or backfill, violates it at once.

## Transport

`Feed.SSE` frames each frame as one server-sent `changes` event with
`id: <seq>`, so a browser's `EventSource` resumes on its own through
`Last-Event-ID` (`SSE.cursor/1`). A heartbeat is a comment line. The endpoint
owns the socket, as Dispatch's `StreamController` does: open, write the first
frame, then loop on `{:coop_ledger, _}` (advance) and a heartbeat timer
(tick plus a heartbeat comment), and exit on the first failed write.

The endpoint is `SpruceGoose.Web.FeedController`:

```
GET /api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/feed
```

It is a transport adapter only. CoopSubstrate decides what a reader sees and
whether it may read; SpruceGoose's own actors and grants play no part.
Responses: `200` and the stream; `400 invalid_cursor`; `409 cursor_ahead`
(start again from 0); `401 unauthorized` with `WWW-Authenticate: CoopFeed`
for every authentication or authorisation failure (the reason is logged, not
returned).

## Access

Decided 2026-10-18: identity and collaboration are delegated, authority is
not. WorkOS will authenticate humans and Buzz is the collaboration surface.
Which actions are valid, including who may read a project, stays with the
ledger's grants. There is no second principal registry and no grants copied
into another system.

A reader must hold an active **operator, suggester or reviewer grant for
exactly the requested scope** (reviewers since
[execution](2026-10-19-execution.md)). A person signed in who holds a
governance key of the chapter, declared for them, reads every project in it
as an administrator, until the key is revoked
([administration](2026-10-19-administration.md)). A delegation confers no read access. `Feed.Access` is the
pure decision; `Feed.authorize/2` applies it to the appender's current gate
(`Log.gate/0`) and spends the request's nonce.

**Agents** sign each read with their grant's key:

```
Authorization: CoopFeed grant="<grant event id>", key="<key id>",
               ts="<unix ms>", nonce="<16-128 chars>", sig="<base64url Ed25519>"
```

The signature covers the canonical encoding (`Access.signing_bytes/1`) of
`{schema: "CoopFeedReadV1", method, path, chapter_id, tenant_id, project_id,
cursor, timestamp_ms, nonce, authorization_event_id, key_id}`, rebuilt by the
server from the request it actually received. A signature for another path,
scope or cursor therefore fails. A request is fresh within 60 s either way of
the server clock, and its nonce is accepted once (`Feed.Nonces`, spent only by
a request that passes). Checks run in this order: nonce shape, freshness,
grant known (`:unknown_grant`), active (`:grant_revoked`), scope
(`:scope_mismatch`), key (`:key_mismatch`), signature (`:bad_signature`).

**People** present the `bizkit_session` cookie from signing in
([identity](2026-10-18-identity.md)). The session names a biz-kit principal,
and that principal's active operator grant on the scope (else its suggester
grant) is the reader (`Access.for_principal/3`, `Feed.authorize_principal/2`).
A request with an `Authorization` header is always treated as signed. A
session authorises reads only: writes still need the principal's own device
key, and a server never signs in a person's name. A stream also ends when its
session ends (logout, expiry, an unbound identity).

**Revocation.** A session opened for a reader serves only the reader's scope
and checks the reader's grant after every event it folds. At the first event
after which the grant is inactive, the session returns `:revoked` and sends
nothing from that batch, and the endpoint ends the response. A lost
notification is caught by the heartbeat's tick. The reconnect is then refused.

## Verification

- `ChangeFeedViewTest` (properties over the generated histories shared with
  `TaskSuggestionsPropertiesTest`, now in `test/support/task_histories.ex`): a
  client applying frames reaches the server's view however events are
  batched; a frame names only entities that changed, each once; frames encode
  as JSON and carry no public keys; another project's view stays empty. A
  seeded coverage test shows the histories put all three kinds in the view.
- `ChangeFeedTest`, against the real appender: snapshot at 0, live frames,
  resume, overlap, gap backfill, tick after a lost notification, other
  projects, refused cursors, close, SSE framing.
- Mutations: removing the backfill, the tick or `open/2`'s cursor check each
  fail a test. Removing `advance/2`'s drop of already-delivered envelopes does
  not: backfill alone then absorbs duplicates, at the cost of a store read, as
  the model also shows.
  The register-before-read order has no deterministic test; the model's
  `noLossReadingFirst` witness is what pins it.
- `FeedAccessTest`: operator and suggester readers; the signature binds
  method, path, cursor, time and nonce; wrong scope, wrong key, a delegation,
  a revoked grant, stale and malformed requests are refused; a nonce is
  accepted once and not spent by a refused request; sessions refuse other
  scopes and revoked grants, end at the revocation without its batch's frame,
  end on a tick after a lost notification, and ignore other grants'
  revocations. Removing any one of these checks fails a test.
- `SpruceGoose.Web.FeedTest`: refusals through the router (no or malformed
  credentials, forged signature, other project, other path or cursor, stale,
  replayed, revoked, bad and future cursors) and live streams on a real
  server (snapshot then live frames, the stream ending on revocation,
  cross-project isolation, reconnect from `Last-Event-ID` without gaps or
  repeats).

## Limits

- Each session folds the whole ledger once on open and keeps its own copy of
  the gate. Fine at today's size. Shared per-scope state can replace it
  without changing the contract.
- Spent nonces live in one process for the whole [cluster](2026-10-19-cluster.md), and every node's
  feed sessions are notified of each append (`:pg`).
- A cursor is a position, not a hash. A client resuming against a restored
  ledger of the same length or longer cannot tell. Adding the head hash would
  close that.
