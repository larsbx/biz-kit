# Location sharing: consented, signed, and kept only within consent

Date: 2026-10-22. Status: **implemented** in `Dispatch.Operations.Locations`,
`ConsentGrant`, `LocationSample` and `DispatchWeb.LocationController`. The
client is the d-patch field app (its ADR-0013); d-patch's scenario 2 runs
against it end to end.

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

## Limits

- No map, geocoder or router yet: those are the next parts of Slice 2.
- The "known skew bound" is the fixed five-minute future bound; per-device
  clock-offset tracking is not built.
- Brokers see no location at all: summary location for brokers comes with
  the partner surfaces.

## Verification

`test/dispatch/operations/locations_test.exs` (consent, each rejection, the
revocation race, geography storage), `test/dispatch_web/location_controller_test.exs`
(the routes, `207`, the `413` batch cap, scenario 2 on the page). Mutation
checks: revocation ignored, signature unchecked, another trip's grant
accepted, any route suffix, no batch cap; all caught. d-patch's
`location.spec.js` against `scripts/e2e-stack.sh`, and the shared signing
vector `location_sample`.
