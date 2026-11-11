# Minimal God's Eye View integration

Date: 2026-11-11.

## Decision and scope

Reuse an attributed subset of God's Eye View's portable globe constructor in
the existing Dispatch portal. The first screen is `/operations/map`: a globe,
latest authorized participant observations, accuracy/freshness, a fit control,
and links to existing participant pages. The observations describe reporting
devices; assigning a person to a vehicle does not establish that vehicle's
physical position.

The upstream source is `bilawalsidhu/gods-eye-view` at
`14db73f201a0235da4f591648d9b6a9bf4fed87f`. Its source attribution, retained
code and modifications are recorded beside the vendored module. Cesium is the
only added browser runtime dependency and is pinned to `1.138.0`. Phoenix
serves a narrow engine bundle and local Natural Earth imagery. The host uses
`CesiumWidget`; the unused higher-level widgets and Knockout are excluded so
module loading works under Dispatch's prohibition on evaluated JavaScript.

The standalone GEV application, Vue/Pinia, public observation feeds, simulated
traffic, voice, MCP, API-key management, provider proxies, sharing and cinematic
effects are outside this increment. No GEV datasets or 3D models are imported.
No additional application server, datastore, scheduler or business writer is
introduced. Existing clients and the MapLibre/routing direction remain usable.

## Read contract

| Route | Contract |
| --- | --- |
| `GET /operations/map` | Authorized document shell; embeds no coordinates |
| `GET /ui/operations/locations` | Complete versioned JSON snapshot |
| `GET /ui/operations/locations/stream` | SSE `dispatch-locations` events, each a complete snapshot |

All three use the existing portal identity session and one selected role.
`LocationSnapshot` revalidates the role and requires both
`operations.participant.read` and `operations.location.precise.read` in
organization scope. No seeded profile is widened. The roster is bounded by
both tenant and organization and contains active participants only.

The projection includes a position only when its exact consent grant is
currently active and covers the sample's participant, assignment and acquisition
time. Granting consent again cannot reveal a sample from a revoked grant.
Positions carry `lat`, `lng`, `accuracy_m`, `occurred_at`, `received_at`,
`provider` and `is_mock`; device and grant identifiers stay inside Dispatch.
No applicable sample produces `position: null`.

The first version serves a complete roster of at most 200 active participants.
It queries one additional row to detect overflow. A larger roster returns
`status: "capacity_exceeded"` and an empty participant list: it never presents
a partial fleet as complete. Filtering/pagination can be added separately.

Snapshots are reauthorized on events and the existing 20-second heartbeat.
The originating identity session is rechecked too. Reconnection obtains a new
snapshot; `Last-Event-ID` does not replay coordinates under former authority.
An authorized subscription joins the existing location-demand groups, including
for consenting participants whose first sample has not arrived. Consent/roster
changes update those memberships. Disconnect, refusal and request cleanup
release the stream process's memberships.

## Browser behavior

The browser holds only the current snapshot in memory. A complete replacement
removes absent or unauthorized positions. Disconnect, an invalid response and
the liveness deadline clear the observations. Reconnection starts with a fresh
authorized read and has bounded retries. A refused read stops retries.

The renderer uses observations without extrapolation, displays accuracy and
age, labels mock observations, and reuses Dispatch's provider-independent
freshness thresholds: gray at 120 seconds and `STALE` at 300 seconds. The
provider label describes what the device reported; it is not independent proof
of physical location. Position freshness does not authorize a business action.

No coordinates enter URL state, browser storage, analytics or server-rendered
HTML. Participant links contain only their existing opaque identifiers.
Every data response is `no-store`. The page has no operational write controls.

Only this page allows Cesium's style attributes, local worker blobs and
WebAssembly initialization through its CSP. Script sources stay same-origin,
with no inline/evaluated JavaScript. The specific `wasm-unsafe-eval` permission
is limited to WebAssembly by the [CSP specification](https://w3c.github.io/webappsec-csp/).
The build selects Meshoptimizer's supported decoder-only entry, excluding
its unused encoder, simplifier, clusterizer and tangent generator.
Imagery, assets and data are same-origin; other portal pages retain their
existing CSP. Required upstream attribution remains visible.

## Packaging and acceptance

The asset package under `tools/dispatch-globe` locks Cesium and a build-only
esbuild version, bundles explicit engine exports, and stages the required
browser files into Dispatch's static assets. Generated
assets and `node_modules` are ignored by Git. Stage them before constructing a
Dispatch release; Node is not needed by the running Phoenix service.

Backend acceptance covers scoped reads, exact sample consent, revocation and
expiry, acquisition ordering, bounded complete snapshots, device demand and
source-session termination. Frontend acceptance exercises schema rejection,
removal, staleness, disconnect/reconnect and an actual Cesium browser render
under the map CSP. These checks use controlled test observations, not a
production tracker or vehicle deployment.

Stop geocoding, route overlays, vehicle-position attribution, assignment
controls and agent queries remain later increments. They should use the
existing geographic provider and operational admission paths when added.
