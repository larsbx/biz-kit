# Dispatch spatial workspace and minimal stack

Date: 2026-11-11 (America/New_York).
Status: **Accepted roadmap; implementation pending. The legacy auxiliary stack
was proposed only.**

Owner clarification, 2026-11-11: the earlier auxiliary stack was **proposed,
not implemented**. This corrects the operating-baseline inference in
[PR #369](https://github.com/larsbx/biz-kit/pull/369). The work is to select and
build the smaller stack directly; no legacy-service retirement sequence is
required. Existing Dispatch application capabilities are identified separately
below.

## Outcome and selected direction

Use God's Eye View (GEV) as Dispatch's spatial workspace. Reuse its scene,
controls, layers, search, drawing, tools and briefing presentation; concentrate
new code in one authorized Dispatch spatial service, one Dispatch layer, a
shared tool catalog and a focused application profile. Preserve the field app
and the existing business forms while integrating them with map selections.

The intended lean deployment is GEV plus Dispatch and its existing durable
storage. Select routing and optimization only when the workflows need them.
Use suitable hosted tiles and geocoding to avoid implementing local providers.
Add Traccar only if required device protocols are not covered by d-patch's
native collection path. The unused parts of the earlier proposal can be omitted
from the first build.

This roadmap records the owner's direction to maximize useful GEV functionality
while avoiding duplicate application work and unnecessary operating components.
Its merge does not claim an integrated deployment, measured resource savings or
physical-device acceptance. Implementation milestones remain open.

## 1. Source baseline and current limits

| Source inspected | Pinned revision | What the inspection establishes |
| --- | --- | --- |
| [Biz-kit][biz-source] | `3e485d281b95e8f5eab4e5ac522ad3b73dec8944` | Dispatch board and native location admission exist; the participant map is scaffolding; geographic provider ports remain unconfigured |
| [God's Eye View][gev-source] | `14db73f201a0235da4f591648d9b6a9bf4fed87f` | Reusable source components, external provider interfaces, layers, tool composition and presentation controls are available |
| [Truck Dispatch][truck-source] | `7201e7102ab8bbbd99a59d7391a00e515dd6bc1c` | Design artifacts describe six proposed auxiliary services; the owner confirms that the legacy stack was not implemented |

Refresh these revisions at implementation kickoff. Pin d-patch's actual client
revision in cross-repository acceptance; this audit does not invent a client
head or reuse an older run as new integration evidence.

### Existing Dispatch surfaces

- The [participant page][participant-page] renders authorized coordinates as
  text. The [map element][participant-map] expects a `map-data` endpoint absent
  from the inspected [router][dispatch-router]. Google adapter scaffolding and
  a planned MapLibre migration are not a working fleet-map deployment.
- The [board contract][board-contract] implements organization-scoped loads,
  stops, trips and fleet reads, versioned writes, idempotency and audit.
  Its roster endpoint is not a live fleet-position projection; stop addresses
  are not automatically geocoded geometry.
- [Native location sharing][location-contract] admits signed, consented samples
  into PostGIS and implements authorized viewing demand. Its browser/emulator
  acceptance is test-stack evidence, not physical-device or production evidence.
- [Geo ports][geo-ports] require search, reverse lookup, routes and matrices.
  The inspected [unconfigured adapters][geo-unconfigured] refuse requests;
  proposed provider configuration does not establish implemented Dispatch
  adapters.
- The [assignment-ledger slice][assignment-ledger] is implemented but the board
  still writes rows. Parity, command switching and writer fencing remain
  separate work. Spatial reads must use the currently authoritative state;
  actions must use the admitted command interface current at integration time.

### Earlier proposed auxiliary stack

The [composition][truck-compose] names PostgreSQL/PostGIS, Traccar, Nominatim,
Valhalla, VROOM and TileServer GL. Its [operator material][truck-operator] and
[deployment script][truck-deploy] describe intended configuration, including a
Traccar database and sample map datasets. For this roadmap these are proposal
artifacts, not an implemented or operating baseline; deployment wording in those
older documents does not override the owner's clarification.

The separate MapLibre operations application was also part of the proposed
direction. GEV lets us avoid building it. No existing Traccar history, auxiliary
database consumers or live service shutdown is assumed. The implemented Dispatch
board, native location admission and existing storage remain distinct from this
unimplemented auxiliary proposal.

### Upstream integration limits

GEV's [application contract][gev-application] permits component and service
composition, but its compatibility catalog is page-scoped. Plan one composed
application per page and pin the tested source; do not assume independently
mountable multiple viewers. Omitting a combined view can also omit useful
controls, so validate task behavior after each profile reduction.

The [default route proxy][gev-routes] calls external OSRM services. Route
presentation does not supply a truck-routing engine, matrices or fleet
optimization. The [Directions source][gev-directions] has a distinct route
interface that must also receive the selected adapter. GEV's [analyst][gev-analyst]
queries loaded client data; complete fleet queries must reach Dispatch.
The [security model][gev-security] treats local MCP restrictions as transport
controls, not Dispatch authentication. Provider and bundled-data requirements
are recorded separately from the code license in [data sources][gev-data].

## 2. Selected implementation and avoided components

| Component or capability | Selected treatment | Owner or dependency | Acceptance for the new implementation |
| --- | --- | --- | --- |
| Proposed MapLibre operations application | Avoid building a separate application; use GEV | GEV profile and Dispatch entity layer | Operators complete the spatial tasks with textual alternatives |
| Geographic search, drawing, layers and route display | Reuse native GEV controls | Chosen provider adapters and Dispatch identities | Compatible results across exposed search/route surfaces, including Directions |
| Implemented load entry, assignment forms and trip transitions | Reuse and link first; integrate selectively later | Existing Dispatch command interface | Authorization, version, retry and admission parity for new entry points |
| Proposed local TileServer GL | Omit when selected hosted imagery meets the requirements | Selected imagery provider; self-hosted option only when needed | Operating-area coverage, attribution, availability and any offline requirements |
| Proposed local Nominatim | Omit when selected hosted geocoding meets the requirements | Selected geocoder shared with backend uses | Forward/reverse search, expected volume and address/coordinate provenance |
| Proposed Traccar | Add only for required hardware protocols | d-patch/Dispatch for native collection; tracker adapter if needed | Actual device, ingestion, retention, reconnect and field acceptance |
| Proposed dedicated Traccar PostgreSQL/PostGIS | Omit with Traccar; provision only if the selected tracker needs it | Storage owner for any newly implemented tracker | Declared storage and recovery contract; no pre-existing tracking data assumed |
| Proposed Valhalla | Select a routing engine when routing is required; Valhalla is a candidate | Routing provider behind Dispatch ports | Truck profiles, constraints, matrices and failure semantics where required |
| Proposed VROOM | Select an optimizer when allocation/stop-order optimization is required; VROOM is a candidate | Optimization provider and Dispatch business inputs | Capacity, time-window, eligibility and commitment constraints |
| Implemented Dispatch storage, identity, consent and command admission | Reuse; follow existing consolidation | Existing platform/domain owners | Existing migration and acceptance contracts |

The benefit is avoided implementation and a smaller chosen deployment. GEV
supplies presentation; actual providers still supply maps, geocoding, routing
and optimization. Reusing native Dispatch collection can avoid introducing a
parallel tracker.

### Capability profiles for the first build

| Profile | Components needed | Proposed components that can be omitted |
| --- | --- | --- |
| Fleet workspace | GEV, authorized Dispatch spatial reads, existing storage/native collection, selected map imagery | Separate MapLibre application, Traccar and its database; local tiles/geocoder when hosted providers suffice |
| Route planning | Fleet workspace plus accepted geocoding/routing providers; optimizer only for optimization workflows | Any unselected local engine or solver; hosted providers remain external dependencies |
| Hardware tracking option | Explicit protocol adapter, such as Traccar, and its required storage | Hardware-tracking services when all required devices use native collection |
| Self-hosted cartography option | Local tiles/geocoding only for a demonstrated coverage, control or offline requirement | Local cartography services in the hosted-provider profile |

These are design choices, not successive six-to-four-to-two service cutovers.
Do not deploy all six proposed services merely to remove them later. Counts, if
reported, must distinguish proposed components omitted from the build from
actual measured runtime components. Routing/optimization deferred from the
fleet-view pilot must be visibly unavailable until implemented.

## 3. Architecture and shared contracts

| Boundary | Responsibility |
| --- | --- |
| Biz-kit / `apps/dispatch` | Authorized spatial reads, complete queries, typed observations, current business state, command entry points and their tests |
| d-patch | Device identity, explicit collection consent, signed samples, offline/reconnect behavior and physical-device acceptance |
| GEV integration package/profile | Rendering, selection, following, native controls, tool presentation and lifecycle cleanup; exact upstream pin and update procedure |
| `truck-dispatch` | Selected optional provider deployment profiles, image/data pins, operating-area coverage and recovery for components actually implemented |
| Routing, optimization and map providers | Calculations and datasets under declared source, coverage and freshness contracts |

Keep the canonical roadmap here and link implementation evidence from companion
repositories. Choose the GEV package's concrete source/build location during
GEV-00; that routine choice must fit existing release ownership and avoid a
second Dispatch backend. A focused application page can host the composed GEV
experience while the current server-rendered portal retains its small-JavaScript
contract. Do not silently turn every portal page into the full GEV shell.

The [one-source-of-truth direction](../architecture/2026-10-11-single-source-of-truth.md)
and [storage/provider separation](../architecture/2026-10-30-postgres-event-log-redis-consolidation.md)
continue to apply. Do not introduce a competing business log, scheduler,
permission registry or independent assignment writer. Routing/map datasets are
not reconstructible from business events, and expiring caches cannot replace
location history or consent records.

### Spatial read model

Specify the contract before implementing multiple clients. The following are
required semantics, not an existing endpoint or finalized wire schema:

- Stable typed references distinguish participants, vehicles, assignments,
  loads/trips, stops, business locations and observations. Relations are explicit;
  a participant observation does not automatically establish vehicle identity.
- Every response declares its authorized scope, requested area/time, source
  revision or watermark, generation time, coverage, pagination and completeness.
  Bounded or partially loaded results cannot answer as a complete fleet count.
- Observations preserve acquisition and receipt times, accuracy and provenance.
  Declared status, observed location, estimated ETA, planned route and admitted
  business event remain distinct. GPS proximity is not delivery evidence.
- Coordinate units and coordinate order are explicit. Convert signed fixed-point
  samples to WGS84 presentation at a checked adapter boundary; retain original
  identity and timing. Malformed/out-of-range coordinates are refused.
- Precise reads reuse current principal, organization, capability and consent
  checks. Every stream, reconnect, selected-record fetch and tool query enforces
  the same policy. Current access is not inferred from a saved view or a cache.
- Reconciliation declares snapshot/update ordering and deletion semantics.
  Scope change, logout and revocation invalidate old requests; a delayed result
  cannot restore cleared coordinates, cards, query results or subscriptions.
- Private coordinates and credentials stay out of share links, browser navigation
  URLs, DOM attributes, browser persistence, analytics and logs unless a separately
  scoped feature explicitly authorizes the relevant storage. Provider requests
  use only the data needed for their selected purpose, with private request
  parameters redacted from logs.

Location demand is a server-owned subscription lifecycle. An entitled viewer
starts or renews the appropriate watch; release, disconnect, permission loss
and failure stop it under a documented bounded cleanup policy. Generic client
polling does not substitute for this behavior. Preserve Dispatch's
[freshness thresholds][map-freshness]: gray at 120 seconds and `STALE` at 300
seconds. Show observation age/accuracy independently of camera animation. These
labels describe age, not priority or routing severity. No fabricated vehicle
movement between observations.

### Tool and command model

One Dispatch tool implementation should serve buttons, voice and agent entry
points under equivalent authorization. Distinguish current-view queries from
server-backed complete-fleet queries and identify partial/unknown answers.
Untrusted map/feed text cannot choose provider URLs, identities or authority.

Planning returns candidates tied to source versions and stated assumptions.
Commands bind exact targets and expected versions, use the existing idempotency
contract, and revalidate current authority at admission. The first workspace
opens existing forms; later map actions must preserve the same rules. GEV's
local MCP server is not a remote business identity provider. Reusing tool
definitions does not authorize exposing or reviving a retired platform `/mcp`
endpoint.

## 4. Sequenced implementation

| ID | Deliverable | Dependencies | Status at roadmap adoption |
| --- | --- | --- | --- |
| GEV-00 | Requirements, source pins and minimal application profile | Existing source contracts and owner correction | Source baseline recorded; profile selection pending |
| GEV-01 | Spatial contract, proof obligations and authorized read service | GEV-00 | Planned |
| GEV-02 | Fleet workspace and native controls | GEV-01 | Planned |
| GEV-03 | Complete queries, geocoding and planning adapters | GEV-01, GEV-02 | Planned |
| GEV-04 | Operational command integration | GEV-03 and current command-path acceptance | Planned |
| GEV-05 | Route context, annotations and operating areas | GEV-02; GEV-03 for route correlation | Planned |
| GEV-06 | History, private saved views and Director handoffs | GEV-01, GEV-02 and retained history | Planned |
| GEV-07 | Minimal deployment and profile acceptance | GEV-00, GEV-02 and each selected capability's acceptance | Planned |
| GEV-08 | Demand/capacity and business-network analysis | Relevant GEV-03/05/06 results and defined business metrics | Later extension |

GEV-05 and GEV-06 can proceed independently after their prerequisites. GEV-07
accepts the selected initial profile without waiting for every advanced feature.
No legacy deployment, data migration or shutdown gate is a prerequisite for
building this unimplemented auxiliary stack. Set delivery estimates after the
profile and device requirements are selected.

### GEV-00 — Requirements and focused profile

**Deliver:** exact source/build pins; required device types; provider and dataset
coverage; data ownership for selected components; and one minimal application
profile with live operations, planning and review modes. Record the owning
repository and build/update procedure for the GEV package. Identify which
features are required initially and which are optional or deferred.

**Acceptance:** distinguish implemented Dispatch source capabilities from the
earlier unimplemented auxiliary proposal. Record the selected providers and
why each local component is needed. Set measurable startup, bundle/network,
browser and service resource budgets before testing the new implementation.
Measure that implementation directly; there is no measured legacy runtime to
use as a before/after baseline.

Activate fleet/current work first. Weather, cameras, street imagery and expensive
effects are task-selected. Disabled layers must not register background feed
work. A commercial profile must exclude unsuitable bundled data from its build,
not merely hide its switch; retain required source attribution. Validate omitted
view dependencies and one-application-per-page lifecycle behavior.

### GEV-01 — Contract and authorized spatial service

**Deliver:** the versioned spatial contract, bounded snapshot/update service,
typed server projection and location-demand integration. Model the authorization,
scope-change and reconciliation invariants before connecting protected data.
Use the existing proof/test framework rather than creating a parallel verifier.

**Acceptance:** positive same-organization observations and meaningful negative
controls for foreign scope, absent precise capability, expired/revoked consent,
session/role changes, malformed coordinates, stale cursors and delayed responses.
Reconnect takes a freshly authorized snapshot; scope changes clear all precise
surfaces; duplicate/out-of-order updates preserve the declared ordering rule.
Opening, closing and crashing a viewer exercise bounded demand cleanup.
Viewing and selecting produce no business mutation.

State Lean propositions and assumptions explicitly where used. Quint establishes
only the explored finite model. Map actual HTTP/database/stream behavior to the
model with integration and race tests; no proof of Cesium rendering, sensor truth
or external provider availability is claimed by a model.

### GEV-02 — Fleet workspace

**Deliver:** the composed GEV page, one Dispatch layer, stable selection cards,
record links, actual observations, accuracy and freshness, fleet/work filters,
native geographic search and appropriate camera controls. Stops without accepted
coordinates remain visibly unresolved; do not invent positions to fill the map.

**Acceptance:** one organization completes a live observation-to-record flow;
another organization's records stay absent. Permission loss clears markers,
selection, followed targets and cached details. Delayed samples remain delayed
through reconnects. Follow/restore uses explicit Dispatch entity support rather
than aircraft/satellite identifiers. The same facts remain accessible as text.
Representative browser/device tasks meet GEV-00 budgets.

Any shared deployment uses the selected Biz-kit authentication and provider-access
boundary. GEV's development server and local MCP restrictions do not establish
multiuser identity or authorization. A local test deployment remains labeled
as such; authenticated hosting is required before sharing protected fleet data.

Complete the spatial interface using GEV and omit the parallel MapLibre
application from the implementation plan. Existing business forms, textual facts
and native field collection continue to work. Keep upstream simulated road
traffic optional and clearly distinguished from Dispatch observations. No
unrelated fleet, aerospace or simulation layer becomes a default requirement
merely because upstream bundles it.

### GEV-03 — Queries and planning

**Deliver:** record resolution, complete authorized fleet queries, area filtering,
shared geocoder/router adapters, current/proposed route overlays and optimization
candidates when the selected profile includes a solver. Reuse GEV's tool catalog
and provide both generic geospatial and Directions source adapters.

**Acceptance:** mouse, voice and tool calls return equivalent permitted records.
Viewport and complete-fleet counts include explicit coverage/pagination. Provider
outage yields unavailable or visibly stale results, never a fabricated zero ETA
or an operational route derived from a direct-line fallback. Routes state engine,
profile, input versions, calculation time, distance, duration and limitations.
Verify matrices, truck constraints, service times, capacity, eligibility and time
windows wherever the proposed planning workflow depends on them.

Public interactive OSRM and Photon defaults are not a fleet capacity plan.
GEV's Nominatim route is disabled until the operator explicitly selects an
endpoint; choosing a public instance does not establish capacity for fleet use.
Select self-hosted or hosted services for declared geography and request volume.
One chosen contract must serve backend planning and exposed frontend route/search
surfaces; replacing a browser endpoint alone does not implement the backend port.

### GEV-04 — Admitted operational actions

**Deliver:** selected map actions that call the existing Dispatch command
interface, initially by opening the appropriate existing form. Add direct action
controls only where they save a demonstrated workflow step and retain admission.

**Acceptance:** exact record binding, current authority, stale-version refusal,
idempotent retries, assignment/equipment constraints and audit remain intact.
Rejected actions change no business state. Lost responses, double submission,
permission changes and concurrent assignment proposals are exercised against
the actual command path, not just a UI mock.

Track the separate assignment-ledger migration explicitly: row/fold parity,
session-to-key authority, profile semantics, command switch and table-scoped
writer fence. The GEV integration neither bypasses that work nor claims it
finished. Use the accepted writer for the operation at the tested revision and
update the adapter when its governed migration occurs.

### GEV-05 — Context, geography and exceptions

**Deliver:** optional route-relevant weather, cameras/street imagery, entrance
and staging annotations, geographic queries and versioned operating areas.
Reuse native drawing and viewing controls; keep correlation and durable rule
meaning in Dispatch.

**Acceptance:** a contextual exception identifies the affected route/stop,
spatial relationship, observation or forecast time, applicable time window,
source and rule. Distinguish observed conditions from forecasts at expected
passage time. Coverage gaps remain explicit. A drawn shape is an annotation
until an authorized save assigns owner, purpose, effective interval and rule.
Geofence behavior accounts for accuracy and repeated boundary observations.
No arrival/delivery proof is inferred solely from proximity or an image.

Private depot cameras use a scoped provider adapter. Place notes and imagery
show their provenance and age. Disabling a context layer releases its work;
context is not a dependency for opening the fleet view.

### GEV-06 — History and handoff

**Deliver:** bounded historical endpoints, replayable observations/events,
authenticated saved-view references and Director briefings. Reuse GEV's
[clock][gev-clock] and [historical source contract][gev-history] after Dispatch
supplies retained history and authorization.

**Acceptance:** historical authorization is explicit; present consent is not
assumed to authorize every historical interval. Replay excludes observations
after the selected cursor and shows gaps and layers that remain live. Distinguish
what happened from what was known then using acquisition/event and receipt times
where the retained data supports both. Do not invent missing receipt history.

Saved views and briefings use opaque references resolved under the recipient's
current access. Restoring camera/selection state grants no record access and
places no private coordinates or credentials in public links. Shared/exported
scene packs and evidence references have explicit disclosure rules; reauthorize
each permitted record before building an export. Exercise expiry, revocation,
missing records and a recipient with narrower access.

### GEV-07 — Minimal deployment and profile acceptance

**Deliver:** a reproducible deployment containing only the selected components,
accepted provider configurations, measured resource use and recovery procedures
for the implementation actually built. Put optional local-provider configuration
in `truck-dispatch`; the workspace can use hosted providers directly through
the authorized service boundary. Use the selection record below.

**Acceptance:** every installed component has a declared required capability.
Omitted or deferred functions remain explicit. Verify cold start, restart,
provider failure, reconnection and recovery of actual persistent state. Pin
images and datasets, separate secrets and authenticate shared hosting through
the selected Biz-kit boundary. A GEV development server alone is not that host.

For a native-only fleet, do not install Traccar or its proposed database. Add a
hardware-tracker path only when the selected device requirements justify it,
with actual field acceptance. Likewise, implement local tiles/geocoding,
Valhalla or VROOM only if selected for their required capability. No legacy
tracking history reconciliation, last-consumer removal or old-service shutdown
is assumed. Existing Dispatch storage and its separate consolidation work keep
their own contracts.

### GEV-08 — Business-network analysis

**Deliver later:** spatial qualified-demand/capacity views, consolidation
candidates, supplier service areas and collection-point scenarios. Use the
existing business definitions and demand-first pilot metrics rather than
creating a second marketplace interpretation.

**Acceptance:** each metric and recommendation identifies its authorized source,
time horizon, completeness, commitments and assumptions. Candidate matching does
not reserve capacity, accept an order or establish financial settlement. Add
air/port/intermodal context only when actual shipment relationships need it.
These features are not prerequisites for the first live workspace or its
minimal deployment.

## 5. Acceptance and evidence ledger

Each implementation PR updates the milestone status with its exact source head,
test profile, result links and unresolved boundaries. Use these distinct labels:
`planned`, `implemented`, `local-verified`, `hosted-verified`, `field-verified`
and `deployed`. Track component selection separately as `selected`, `optional`,
`deferred` or `omitted`. A label for one capability does not promote another.

| Evidence area | Required observation |
| --- | --- |
| Scope and revocation | Authorized positive case; foreign/expired/revoked refusal; late results cannot restore access |
| Location lifecycle | Actual admitted sample, explicit age/accuracy, demand join/release and reconnect behavior |
| Complete queries | Coverage, bounding and pagination are visible; viewport subsets never masquerade as fleet totals |
| Planning | Source-bound candidates, required vehicle/business constraints and truthful provider-failure behavior |
| Commands | Existing admission, current authority, versions, idempotency, concurrency and audit |
| History and sharing | Authorized time range, gaps, receipt-time limits and recipient-specific restoration/export |
| Packaging and operation | Pinned sources, disabled-feed inactivity, attribution, representative resource budgets and restart/fallback |
| Minimal deployment | Only selected components installed; omitted capabilities explicit; actual runtime measurements and recovery verified |

Reuse applicable location cross-repository, portal authentication, Dispatch
database and command acceptance lanes. Add focused checks for the new adapters
and GEV lifecycle, not a duplicate broad test platform. A synthetic client or
browser emulator result stays labeled as such. Models, source inspection,
hosted CI, physical-device tests and production observations are separate forms
of evidence. This documentation change performs none of the runtime gates.

### First substantial acceptance scenario

An authorized operator opens an active trip, sees its latest admitted location,
age and accuracy, selects the next stop and opens the corresponding Dispatch
record. A second organization sees none of those private records. Revoking the
first operator's access clears all precise displays and ends the relevant
watch; a delayed response and reconnect cannot resurrect it. Selection produces
no business mutation. This is the GEV-01/02 release target.

Extend that scenario in later milestones: a complete-fleet query identifies
relevant work, a routing/optimization provider returns a versioned candidate,
the existing command interface admits the selected change, and another entitled
operator restores a private work view under their own permissions.

## 6. Component selection and deployment acceptance record

Record one row per component/profile during GEV-00 and update it with GEV-07
implementation evidence. Empty evidence means pending, not implemented.

| Field | Required content |
| --- | --- |
| Component and capability | Exact application, local service or hosted provider; operating area and required behavior |
| Selection | Selected, optional, deferred or omitted; reason it is needed or can be avoided |
| Owner and contract | Repository/provider, source/build revision, interface and declared dependencies |
| State | Actual persistent state generated or used by the selected implementation, with owner and retention |
| Acceptance | Exact-head local/hosted/field results and actual deployment observations as applicable |
| Recovery | Reproducible startup, provider failure handling and restore procedure for actual persistent state |
| Measurements | Running components, memory/CPU, startup, operational latency and external usage for the tested workload |
| Final status | Implementation/evidence state, owner and date |

The proposed auxiliary stack supplies no presumed data to migrate or services
to shut down. Initial acceptance therefore concerns the new selected deployment.
Preserve existing Dispatch state and its established recovery procedures.

If later work identifies an actual running dependency outside this clarified
baseline, record it separately and define the migration appropriate to that
dependency. Do not turn a hypothetical discovery into a mandatory legacy
migration phase for this roadmap.

## 7. Immediate implementation order

1. Complete GEV-00's minimal profile and device requirements; pin the GEV build,
   choose providers and define representative performance/resource budgets.
2. Implement GEV-01's contract/model and authorized read adapter with negative
   controls. Follow with GEV-02's fleet layer and the first acceptance scenario.
3. Connect the chosen geocoding/routing services and complete operational queries
   through GEV-03. Preserve current Dispatch command entry points while their
   separate ledger migration advances.
4. Accept the minimal deployment through GEV-07 using only selected components.
   Add hardware tracking, local cartography or optimization only when needed.
   Context, history and handoff can advance independently behind their own gates.

Build the smaller architecture directly. The earlier auxiliary proposal does
not need to be implemented, migrated or retired first.

## Sources

The source revisions above remain immutable; the interpretation of the legacy
proposal is corrected by the owner's 2026-11-11 clarification. New implementation
claims require new evidence and must not be inferred from the older deployment
wording.

- Dispatch contracts: [location][location-contract], [board][board-contract],
  [geographic ports][geo-ports] and [assignment-ledger migration][assignment-ledger].
- Earlier auxiliary proposal artifacts: [composition][truck-compose],
  [operator material][truck-operator] and [deployment script][truck-deploy].
- GEV integration: [application][gev-application], [routing][gev-routes],
  [Directions][gev-directions], [history][gev-history], [security][gev-security]
  and [provider/data requirements][gev-data].

[biz-source]: https://github.com/larsbx/biz-kit/tree/3e485d281b95e8f5eab4e5ac522ad3b73dec8944
[gev-source]: https://github.com/bilawalsidhu/gods-eye-view/tree/14db73f201a0235da4f591648d9b6a9bf4fed87f
[truck-source]: https://github.com/larsbx/truck-dispatch/tree/7201e7102ab8bbbd99a59d7391a00e515dd6bc1c
[participant-page]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/apps/dispatch/lib/dispatch_web/components/operations.ex
[participant-map]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/apps/dispatch/priv/static/js/maps/participant-map.js
[dispatch-router]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/apps/dispatch/lib/dispatch_web/router.ex
[board-contract]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/docs/architecture/2026-10-27-dispatch-board.md
[location-contract]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/docs/architecture/2026-10-22-location-sharing.md
[geo-ports]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/apps/dispatch/lib/dispatch/integrations/geo/ports.ex
[geo-unconfigured]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/apps/dispatch/lib/dispatch/integrations/geo/unconfigured.ex
[assignment-ledger]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/docs/architecture/2026-11-09-dispatch-assignments-on-the-ledger.md
[truck-compose]: https://github.com/larsbx/truck-dispatch/blob/7201e7102ab8bbbd99a59d7391a00e515dd6bc1c/compose.yaml
[truck-operator]: https://github.com/larsbx/truck-dispatch/blob/7201e7102ab8bbbd99a59d7391a00e515dd6bc1c/OPERATOR.md
[truck-deploy]: https://github.com/larsbx/truck-dispatch/blob/7201e7102ab8bbbd99a59d7391a00e515dd6bc1c/scripts/deploy.sh
[map-freshness]: https://github.com/larsbx/biz-kit/blob/3e485d281b95e8f5eab4e5ac522ad3b73dec8944/apps/dispatch/priv/static/js/maps/map-freshness.js
[gev-application]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/docs/APPLICATION.md
[gev-routes]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/server/providers/places/routes.js
[gev-directions]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/src/layers/directions/source.js
[gev-analyst]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/src/data/analystEngine.js
[gev-security]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/SECURITY.md
[gev-data]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/DATA_SOURCES.md
[gev-clock]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/src/time/worldClock.js
[gev-history]: https://github.com/bilawalsidhu/gods-eye-view/blob/14db73f201a0235da4f591648d9b6a9bf4fed87f/src/sources/live/contract.js
