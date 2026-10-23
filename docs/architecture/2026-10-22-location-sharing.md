# Location sharing: consented, signed, and kept only within consent

Date: 2026-10-22. Status: **implemented** in `Dispatch.Operations.Locations`,
`ConsentGrant`, `LocationSample`, `LocationDemand` and
`DispatchWeb.LocationController`. The client is the d-patch field app (its
ADR-0013 and ADR-0014); d-patch's scenario 2 and demand flow run against it
end to end.

## Why

d-patch's specification makes location sharing explicit, visible and
revocable (§6.1), stores samples as PostGIS geography (§28.2), uploads them in
batches answered per sample (§24.2), and requires that revoking consent stop
collection and portal updates, except for samples acquired before the
revocation (acceptance criterion 4). Dispatch had a geography type and the
capabilities, and nothing else.

## Decision

- **A consent grant per trip.** `POST /v1/me/location-consents` with one of
  the participant's own planned or active assignments. It lasts for the
  assignment plus a grace period (`:location_grace_seconds`, default 30
  minutes), or until `POST /v1/me/location-consents/:id/revoke`. Granting and
  revoking are audited. Consenting again while a grant covers now returns it.
- **Signed samples, fixed-point on the wire.** The device signs each sample's
  fields in `CoopEventCanonicalV1` (`DispatchLocationSampleV1`). That form has
  no floats, so coordinates and measurements travel as integers (`lat_e7`,
  `accuracy_cm`, ...) and are stored as `geography(Point,4326)` and metres.
  Unsigned or wrongly signed samples are refused.
- **Each sample judged alone** (`207`): shape, signature, duplicate
  (`(device_id, device_sequence)` is unique across tenants), consent *at
  acquisition*, and the five-minute future clock bound. The consent check is
  the revocation race: a sample acquired before revocation is kept whenever
  it arrives.
- **The route is the specification's custom method**,
  `/v1/me/location-samples:batch`. Phoenix matches `:batch` as a parameter,
  so the controller answers only that exact suffix, and the OpenAPI builder
  writes it back literally.
- **Observation, not position, on the operations page.** The participant page
  shows when the device last reported, with accuracy (`±12 m`, "low accuracy"
  above 250 m) and age, as an `OBSERVED` fact. It never shows coordinates:
  those need `operations.location.precise.read` and active consent, which no
  seeded operations profile holds. A new sample patches open pages through
  the outbox.

## Demand

Real time exactly while someone entitled to the position is looking at it
(d-patch ADR-0014, amending §25.3's single cadence).

- **Who counts.** `LocationDemand.precise?/2`: `operations.location.precise.read`,
  the participant in the viewer's organization, and a consent covering now.
  For that viewer, and no other, the participant page also carries
  `live_position` (the latest sample's coordinates).
- **Watching** is membership of a `:pg` group per participant, joined by the
  viewer's participant stream while `precise?` holds (re-decided each tick)
  and left when the stream ends (`Streams.Participant.release/1`, run by
  `Streams.Transport` in an `after`: Bandit serves the next keep-alive request
  from the same process, so process exit is not enough). A crashed or killed
  stream leaves by exiting.
- **The device hears** on `GET /v1/me/location-demand` (`Streams.LocationDemand`):
  server-sent `location-demand` events whose `data` is the policy, sent on
  opening and on each change, from a `:pg.monitor/2` on the group. `realtime`
  is a sample every 3 s uploaded at once; `trickle` a sample every 2 minutes
  uploaded every 10 (`:location_demand` overrides either). No active consent:
  `404 NO_ACTIVE_CONSENT`. Revalidated at each heartbeat and on each change to
  the participant (a revocation enqueues one), it closes when consent or the
  role assignment ends.
- **Shared transport.** `Streams.Transport` now runs every SSE stream: the
  portal's two and the device's. It subscribes, opens, loops on outbox,
  `:pg` and heartbeat messages, and stops at the first failed write, whatever
  the error (a reset peer reports `:econnreset`, not `:closed`).

## Which trip

`GET /v1/me/assignments` (and the DRIVER projection `/v1/driver/assignments`,
`Dispatch.Operations.Trips`) lists the caller's trips not yet over, soonest
first, each with the consent covering it now or `null`. It is how the app
learns which assignment to consent for, and, after a reboot, the server's
confirmation §25.3 asks for: "the persisted consent is valid and the active
assignment still exists".

`assignment.read.self` is constrained `active_assignment_only` for DRIVER.
Read as *not yet over*: PLANNED or ACTIVE and not past its end, exactly the
assignments consent can be begun for. A status alone makes a trip history,
with or without a recorded end. Completed, cancelled and ended trips are not
this capability's to read.

## Limits

- No map, geocoder or router yet: those are the next parts of Slice 2.
- The "known skew bound" is the fixed five-minute future bound; per-device
  clock-offset tracking is not built.
- Brokers see no location at all: summary location for brokers comes with
  the partner surfaces.
- A watcher who closes their tab is noticed at the stream's next write. While
  the device is live that is its next upload (seconds); a stream with nothing
  to send notices at its next heartbeat or the one after (20 to 40 s).

## Verification

`test/dispatch/operations/locations_test.exs` (consent, each rejection, the
revocation race, geography storage), `test/dispatch_web/location_controller_test.exs`
(the routes, `207`, the `413` batch cap, scenario 2 on the page). Mutation
checks: revocation ignored, signature unchecked, another trip's grant
accepted, any route suffix, no batch cap; all caught. d-patch's
`location.spec.js` against `scripts/e2e-stack.sh`, and the shared signing
vector `location_sample`.

Demand: `location_demand_test.exs` (who counts, join and leave including a
killed viewer), `streams/participant_stream_test.exs` (a precise reader
watches and sees coordinates; a plain dispatcher does neither; consent ending
stops the watch), `streams/location_demand_stream_test.exs` (trickle →
realtime → trickle, no event without a change, revocation closes) and the
`404` in `location_controller_test.exs`. Mutation checks: watching without
`precise?`, coordinates without `precise?`, `precise?` without the
capability, an event on every notification, the device stream not
revalidating consent; all caught. d-patch's `location.spec.js` drives the
whole flow with a seeded `tracker`.

## Integration correction (2026-10-23)

Consent begin and revoke now lock the assignment row in a database transaction
before deciding which grants exist. Concurrent begins with different keys see
one committed grant, and a revoke waiting behind a begin sees and ends its
grant. Assignment completion/cancellation updates that same row before closing
its consents. Audit and refresh writes remain inside the mutation transaction.
`location_concurrency_test.exs` uses separate committed database sessions and
checks PostgreSQL's blocking relationship before releasing the competing write;
a shared sandbox connection would not test this ordering.

The endpoint parses sample batches with a route-specific 256 KiB raw-body cap,
before the general parser, JSON decoding, or signature verification. It returns
413 `BATCH_TOO_LARGE` without trusting Content-Length or JSON re-encoding.
Regressions include whitespace, escaped JSON, both routes, and the exact byte
boundary. The general parser's 1 MB limit remains for other routes.

`Location cross-repository acceptance` tests this server's merge revision
against d-patch main as merged by #20 (pinned `96909d55`), running browser and
both driver/courier emulator lanes. This is test-stack evidence, not production
deployment or physical-device acceptance.
