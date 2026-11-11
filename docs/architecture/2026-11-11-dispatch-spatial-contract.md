# Dispatch spatial read contract, version 2

Date: 2026-11-11. Implementation: [draft PR #371](https://github.com/larsbx/biz-kit/pull/371).
See the [workspace decision](2026-11-11-dispatch-map.md),
[selected profile](../../tools/dispatch-globe/profile.json) and
[formal obligations](../../formal/DISPATCH_SPATIAL_SAFETY.md).

## Scope and authority

The map shell, snapshot and stream require the current portal session and its
selected organization role, `operations.participant.read` and
`operations.location.precise.read`. The selected organization role must have
an unrestricted organization scope, not a record-specific scope. No capability
is added to a default role by this feature.

Each response carries `scope.key`, a SHA-256 identity of the contract version,
tenant, principal kind and ID, selected role-assignment ID and organization ID.
It is an opaque comparison token, not a credential or permission grant. The
authorized shell embeds this expected key without coordinates. Every later
snapshot must match it. The response also names a typed organization reference.
Changing role or organization requires opening a newly authorized page.

The roster contains only active participants of that tenant and organization.
A precise sample must reference its exact still-active location consent grant;
that grant must match the participant and assignment and cover acquisition time.
Replacement consent never revives observations made under a revoked grant.
Missing eligible samples yield `position: null`, not a guessed position.

## Snapshot envelope

`GET /ui/operations/locations` and the `dispatch-locations` SSE event use the
same complete-replacement document. All JSON responses are `no-store`.

| Field | Meaning and constraints |
| --- | --- |
| `schema_version` | Exactly `2`; other versions are refused |
| `status` | `ok` or `capacity_exceeded` |
| `generated_at` | UTC generation time, separate from sample acquisition/receipt |
| `scope` | Expected scope key and `{kind: "organization", id: UUID}` |
| `query` | `{area: "organization", time: "latest"}`; no implicit viewport or historical query |
| `coordinates` | `{crs: "EPSG:4326", units: "degrees", order: "named_lat_lng"}` |
| `source.kind` | `dispatch_location_projection` |
| `source.revision` | SHA-256 digest of scope, status, coverage, work access and projected participants |
| `cursor` | Fresh UUID `stream_id` and a nonnegative, JavaScript-safe integer `sequence` |
| `limit` | `200` active participants |
| `coverage` | Population, completeness, returned count, total, limit and `next_cursor: null` |
| `work_access` | Whether this current read also has separate load and assignment read authority |
| `participants` | The complete bounded authorized roster, including rows with no eligible position |

The revision is content identity only. Authorization, roster, consent and sample
queries recheck current state, but do not form a serializable database snapshot
or a global event-log watermark. Equal content revisions can have different
generation times and cursors. Neither the digest nor a cursor authorizes access.

For `ok`, `coverage.complete` is true and `total == returned == participants.length`.
For `capacity_exceeded`, completeness is false, total is unknown (`null`),
returned is zero and the participant array is empty. One extra roster row detects
participant overflow. The server also refuses an encoded snapshot over 256 KiB
with the same empty capacity response and releases its watches. The client
enforces that byte limit independently. It never
treats an oversized or incomplete response as a complete fleet. There is no
pagination cursor in this version.

Each participant has `participant_id`, an equal typed
`{kind: "participant", id}` reference, a public name and nullable position.
Position fields are:

| Field | Meaning |
| --- | --- |
| `observation_ref` | `{kind: "location_observation", id: UUID}` for the admitted sample |
| `lat`, `lng` | Finite named decimal degrees, within ±90 and ±180 respectively |
| `accuracy_m` | Finite nonnegative reported horizontal accuracy |
| `occurred_at` | Device acquisition time |
| `received_at` | Server receipt time |
| `provider`, `is_mock` | Preserved reported source and mock flag |

Device IDs and consent IDs remain on the server. The browser accepts the
existing acquisition-clock tolerance, but visibly labels a future acquisition
`CLOCK AHEAD`. Age is based on acquisition time: gray at 120 seconds and `STALE`
at 300 seconds. Accuracy, age and provenance do not establish physical truth,
vehicle identity, arrival, delivery or command admission.

## Replacement and ordering

1. A page lifetime starts with a freshly authorized GET at sequence zero.
2. Its first SSE snapshot must begin a distinct fresh stream at sequence zero.
   This is the sole GET-to-SSE handoff. `Last-Event-ID` never resumes old state.
3. Later events must belong to that SSE stream and have a greater sequence.
   Sequence numbers need not be contiguous. Equal/older events are ignored,
   including their generation timestamps; they do not renew liveness.
4. Every accepted snapshot replaces the roster. Absence removes a row or
   observation. Work details are cleared before any permitted fresh work read.
   Withdrawn observations also cause a camera fit using only remaining visible
   authorized positions, or a global reset if none remain.
5. Wrong scope, unexpected stream identity, malformed data or failed currentness
   checks clear precise state. A lost connection clears immediately; a silent
   connection clears by the 45-second client deadline. Server heartbeat
   reauthorization occurs at the existing 20-second interval and on events.
6. Reconnect has a new request generation, GET and SSE lifetime. Old asynchronous
   results cannot restore observations or work. Refused access stops retries.

The server owns location-demand membership. An authorized stream watches the
current consenting roster, including participants awaiting a first sample.
Roster/consent changes reconcile membership; close, failure and authorization
loss release it. A page scope change must not move a subscription to a different
scope. Client disposal aborts work, destroys the renderer and releases its stream.

This is bounded reauthorization, not an instantaneous distributed revocation
guarantee. A grant or role may change between database reads or just after a
response is produced. The heartbeat, event, request-generation and liveness
rules define cleanup; formal guards assume the server observations they receive
are authentic and faithfully represented.

## Observation-bound work

`GET /ui/operations/locations/:participant_id/work` requires one
`x-dispatch-observation: UUID` header. The server checks fresh map authority and
both `load.read` and `assignment.read`, resolves the currently visible exact
sample, follows its actual assignment and reads the organization-scoped load
through `Dispatch.Operations.Board`. It checks visibility again before return.

The work envelope is version `1`, status `ok`, and includes `scope`,
`generated_at`, typed participant and observation references, the actual
assignment, load and ordered planned stops. Assignment data includes status,
version, interval and optional typed equipment references. Load data includes
status, version, reference, commodity text and an opaque-ID operator record URL.
It excludes rates, negotiations, contact details, device keys and consent records.

Stops have typed references, sequence, kind, address, planned window and either
recorded WGS84 geometry or `position: null, position_status: "unresolved"`.
`stop_coverage` declares completeness, returned/total counts and a 200-stop limit.
The first planned stop is not a proven next stop:
`next_stop` is always `{status: "unknown", reason: "stop_progress_not_recorded"}`
until a separately accepted progress source exists.

| Result | Behavior |
| --- | --- |
| `200` | Current authorized work for the requested sample |
| `404` | Missing, invalid or unauthorized target; no foreign-record distinction |
| `409`, `observation_changed` | A different observation is now current; select from the fresh snapshot |
| `422`, `capacity_exceeded` | Encoded work exceeds 64 KiB; no partial work is returned |

The browser binds acceptance to its expected scope, participant, observation and
request generation. Selection change, any accepted snapshot, capability loss,
disconnect or disposal aborts and clears the old details. A hung work request is
cleared after 15 seconds. The standalone operator load page rechecks load and
assignment authority independently and has no location access requirement.

## Presentation and limits

Keyboard or marker selection identifies an explicit Dispatch participant.
Follow tracks that entity using current observations without fabricated motion;
it does not reuse aircraft or satellite identity formats. Keyed roster controls
retain keyboard focus during ordinary snapshot refreshes. The selected work
card and record links also work when WebGL is unavailable.

Roster filtering reports the shown subset and the authorized roster total.
Coordinate search uses the pinned upstream parser locally and moves only the
camera. It does not geocode addresses, query a provider, change authority or
create a location observation. No private state is put in navigation links,
DOM data attributes, browser persistence, analytics or public feeds. Actual
coordinate facts remain available as text to authorized readers.

The [profile](../../tools/dispatch-globe/profile.json) pins the viewer, engine
and build dependency and declares package/network/browser budgets before
measurement. The browser fixture measures real rendering with controlled
records; the independent Phoenix/database suite verifies actual authorization
and joins. Lean propositions and bounded Quint exploration cover modeled
ordering and cleanup only. None establishes sensor truth, physical-device
collection, street-level map coverage, routing availability or deployment.
