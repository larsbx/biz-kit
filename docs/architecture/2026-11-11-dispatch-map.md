# Dispatch fleet spatial workspace

Date: 2026-11-11.

## Decision and scope

Reuse an attributed subset of God's Eye View's portable globe constructor in
the existing Dispatch portal. `/operations/map` contains a globe, latest
authorized participant observations, accuracy/freshness, fit and follow
controls, roster filters, coordinate search and observation-bound work details.
The observations describe reporting
devices; assigning a person to a vehicle does not establish that vehicle's
physical position.

The upstream source is `bilawalsidhu/gods-eye-view` at
`14db73f201a0235da4f591648d9b6a9bf4fed87f`. Its source attribution, retained
code and modifications are recorded beside the vendored module. Cesium is the
only added browser runtime dependency and is pinned to `1.138.0`. Phoenix
serves a narrow engine bundle and local Natural Earth imagery. The host uses
`CesiumWidget`; the unused higher-level widgets and Knockout are excluded so
module loading works under Dispatch's prohibition on evaluated JavaScript.
The selected raster/ellipsoid/point profile also excludes meshoptimizer's eager
WebAssembly initializers. A narrow build adapter explicitly refuses compressed
mesh decoding; it does not weaken CSP or claim support for those unselected
asset formats.

The standalone GEV application, Vue/Pinia, public observation feeds, simulated
traffic, voice, MCP, API-key management, provider proxies, sharing and cinematic
effects are outside this increment. No GEV datasets or 3D models are imported.
No additional application server, datastore, scheduler or business writer is
introduced. Existing field clients and business forms remain usable. The
parallel MapLibre application was proposed only and is omitted from this build;
there is no legacy tracker deployment to migrate or retire.

The selected build profile, requirements and budgets are machine-readable in
[`tools/dispatch-globe/profile.json`](../../tools/dispatch-globe/profile.json).
This is still a derived viewer subset and the upstream coordinate parser,
not the entire composed GEV application. Native drawing, tool composition,
address search, route planning and history remain later roadmap increments.

## Read contract

| Route | Contract |
| --- | --- |
| `GET /operations/map` | Authorized document shell; embeds no coordinates |
| `GET /ui/operations/locations` | Complete versioned JSON snapshot |
| `GET /ui/operations/locations/stream` | SSE `dispatch-locations` events, each a complete snapshot |
| `GET /ui/operations/locations/:participant_id/work` | Separately authorized work for the exact displayed observation |
| `GET /operations/loads/:load_id` | Read-only operator load and planned-stop record |

All routes use the existing portal identity session and one selected role.
`LocationSnapshot` revalidates the role and requires both
`operations.participant.read` and `operations.location.precise.read` in
organization scope. No seeded profile is widened. The roster is bounded by
both tenant and organization and contains active participants only.

The projection includes a position only when its exact consent grant is
currently active and covers the sample's participant, assignment and acquisition
time. Granting consent again cannot reveal a sample from a revoked grant.
Positions carry a typed observation reference, `lat`, `lng`, `accuracy_m`,
`occurred_at`, `received_at`, `provider` and `is_mock`; device and grant
identifiers stay inside Dispatch.
No applicable sample produces `position: null`.

Version 2 serves a complete roster of at most 200 active participants.
It queries one additional row to detect overflow. A larger roster returns
`status: "capacity_exceeded"` and an empty participant list: it never presents
a partial fleet as complete. Client filters operate only on that authorized
roster and show their result count separately. Server area/time queries and
pagination remain later work.

The [V2 wire contract](2026-11-11-dispatch-spatial-contract.md) specifies typed
references, organization scope, coordinate units/order, content identity,
coverage and per-connection ordering. The page embeds only its expected scope
hash. A response for another scope cannot replace its observations. An initial
GET has sequence zero; a new SSE lifetime starts at zero and then increases
strictly. Duplicates and older events cannot restore deleted positions or renew
the browser's liveness deadline. The content revision is a projection digest,
not a database transaction or global event-log watermark.

Snapshots are reauthorized on events and the existing 20-second heartbeat.
The originating identity session is rechecked too. Reconnection obtains a new
snapshot; `Last-Event-ID` does not replay coordinates under former authority.
An authorized subscription joins the existing location-demand groups, including
for consenting participants whose first sample has not arrived. Consent/roster
changes update those memberships. Disconnect, refusal and request cleanup
release the stream process's memberships.

The work read additionally requires fresh `load.read` and `assignment.read`
authority. Its `x-dispatch-observation` header binds the exact visible sample;
the server follows that sample's assignment into the existing authoritative
board read and checks current visibility again. A newer sample returns conflict
instead of substituting different work. The response includes the actual
assignment, load, ordered planned stops, explicit stop coverage and known stop
geometry. No sample is reassigned to a vehicle position. Planned stops are not
trip progress: `next_stop` is explicitly unknown until a progress source exists.
An over-budget work response returns an explicit capacity refusal.

The new operator record route uses board read authority rather than the
partner-only `/loads/:id` surface. It has no write controls and excludes rates,
negotiation and contact details from this spatial view. Its authority is
independent of precise-location permission: an operator may retain a permitted
load read after losing map access.

## Browser behavior

The browser holds only the current snapshot in memory. A complete replacement
removes absent or unauthorized positions. Disconnect, an invalid response and
the liveness deadline clear observations, work details, selection and following.
Reconnection starts with a fresh
authorized read and has bounded retries. A refused read stops retries.
When an individual observation is withdrawn, the camera is refitted using only
the remaining visible authorized observations; removing its marker must not
leave the camera at the withdrawn coordinate. Clearing selected work similarly
returns to current permitted observations after scene reconciliation.

The renderer uses observations without extrapolation, displays accuracy and
age, labels mock observations, and reuses Dispatch's provider-independent
freshness thresholds: gray at 120 seconds and `STALE` at 300 seconds. The
provider label describes what the device reported; it is not independent proof
of physical location. Position freshness does not authorize a business action.

No coordinates enter URL state, browser storage, analytics or server-rendered
HTML. Participant links contain only their existing opaque identifiers.
Every data response is `no-store`. The page has no operational write controls.

Only this page allows Cesium's style attributes and local worker blobs through
its CSP. Script sources stay same-origin, with no inline/evaluated JavaScript.
Imagery, assets and data are same-origin; other portal pages retain their
existing CSP. Required upstream attribution remains visible.

Keyed roster controls preserve keyboard focus across ordinary refreshes.
Selection and follow use an explicit Dispatch participant entity. Local
coordinate search reuses GEV's pinned parser; it moves the camera without
calling a public geocoder or changing the selected business record. Work
fetches have their own cancellation generation and a 15-second deadline.
Unauthorized or changed observation details cannot survive a new snapshot.

## Packaging and acceptance

The asset package under `tools/dispatch-globe` locks Cesium and a build-only
esbuild version, bundles explicit engine exports, and stages the required
browser files into Dispatch's static assets. Generated
assets and `node_modules` are ignored by Git. Stage them before constructing a
Dispatch release; Node is not needed by the running Phoenix service.

The focused [formal gate](../../formal/check_dispatch_spatial.sh) precedes
runtime CI. It builds and audits Lean propositions, runs finite Quint models
and requires deliberate unsafe variants to fail. Its
[safety document](../../formal/DISPATCH_SPATIAL_SAFETY.md) states the model's
assumptions and maps modeled boundaries to real tests.

Backend acceptance covers scoped reads, exact sample consent, revocation and
expiry, acquisition ordering, bounded complete snapshots, separate work
capabilities, exact observation-to-assignment binding, operator records,
device demand and source-session termination. Frontend acceptance exercises
schema rejection, duplicate/older event fences, removal, work-response races,
staleness, disconnect/reconnect and an actual Cesium browser render under the
map CSP. The browser measures package/network/startup/heap budgets with
controlled test observations. These checks do not establish a production
tracker, physical-device acceptance or deployed performance.

Stop geocoding, actual stop progress, route overlays, vehicle-position
attribution, assignment controls and agent queries remain later increments.
They should use the
existing geographic provider and operational admission paths when added.
