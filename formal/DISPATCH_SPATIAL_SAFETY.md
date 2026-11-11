# Dispatch spatial reads: proof and refinement contract

This packet specifies the GEV-01 authorization and reconciliation boundary for
the [version 2 spatial contract](../docs/architecture/2026-11-11-dispatch-spatial-contract.md).
It accompanies the [workspace plan](../docs/plans/2026-11-11-dispatch-spatial-workspace.md)
and extends the existing [Dispatch operations proof framework](DISPATCH_OPERATIONS_SAFETY.md).
The map is a read surface. Selecting, following, filtering, searching coordinates
and inspecting work must not assign equipment, transition a trip, record arrival
or make another business mutation.

The model gate must pass **before** accepting the backend and browser refinement.
Passing models alone do not accept runtime behavior. Require the independent
database, HTTP, stream, JavaScript and browser checks at the same source head.
The source manifest records the files actually checked, including an uncommitted
local candidate; a repository commit ID alone is not evidence that its working
tree was the tested input.

## 1. Source authorization and identity

`formal/lean/BizKitDispatchSpatial.lean` models an expected scope as the tuple
`(tenant, organization, principal kind, principal ID, selected role assignment)`.
The runtime represents this identity with an opaque SHA-256 comparison key
including contract version. Neither representation grants authority. The
authorized page supplies the expected key independently of subsequent frames.

An observation is admitted only when the selected authority matches that scope,
its session and role remain current, and both participant-read and precise-read
capabilities are present. The sample's tenant and organization must match. Its
**original** consent record must match tenant, participant and assignment,
remain active and cover acquisition. A replacement grant cannot disclose a
sample admitted under another grant. `mayObserve` states these guards;
`authorized_observation_is_shown` and the refusal theorems cover acceptance and
missing guards for arbitrary modeled identities.

`ParticipantRef` and `ObservationRef` are distinct Lean types. They represent a
Dispatch participant and an actual admitted observation, not an aircraft,
satellite, inferred vehicle or planned stop. Coordinates and reported accuracy
are abstracted by the presence of that subject in a checked observation set.
Coordinate range, finiteness, timestamp, schema and byte-budget checks are
represented by `Frame.wellFormed` and remain runtime obligations.

The separate Quint source model explores one independently missing guard at a
time, plus an accepted source. It deliberately permits renewed consent in its
unsafe variant. Its independently stated `validDisclosure` invariant then
fails with a concrete disclosure under the wrong grant. Lean additionally
models the consent-to-participant and consent-to-assignment equality guards.

## 2. Client reconciliation and erasure

The Lean state contains expected scope, local request generation, transport
phase, stream identity, sequence, visible observations, selected observation,
work details, work-request epoch, work permission, liveness and watch presence.
Its business version is a separate abstract field that every read transition
preserves.

| State or input | Required transition |
| --- | --- |
| Initial page or fresh reconnect | No observations, selection, work or watch; wait for a newly authorized GET |
| Initial GET | Correct expected scope and current local generation; sequence zero |
| First SSE frame after GET | Same expected scope; distinct stream identity; sequence zero |
| Later SSE frame | Same stream and a strictly greater sequence; gaps are permitted |
| Duplicate or older same-stream frame | Ignore entirely; do not renew liveness |
| Old local generation | Ignore; cancellation need not prevent the callback from arriving |
| Wrong scope, wrong current stream or malformed current frame | Erase private state and stop that lifetime |
| Disconnection, expired liveness or discovered loss of authority | Erase observations, selection and work; invalidate requests; release watches |
| Accepted complete replacement | Replace all visible observations; drop a removed or changed selection; clear work and advance its request epoch |

`cleared_view_cannot_be_restored` applies to **every** later frame while the view
is stopped. A reconnect explicitly creates an empty snapshot phase with a new
generation. It is not permission to reuse old frames. Fresh source authorization
is the server-side precondition of the reconnect GET.

`old_or_duplicate_cursor_is_ignored` proves equality of the entire modeled view
for same-stream non-increasing cursors. `ignored_frame_cannot_renew_liveness`
makes the watchdog rule explicit. The required GET-to-SSE sequence-zero handoff
is separate from this monotonicity rule; treating the GET's zero as an already
accepted SSE zero would incorrectly drop the first live frame.

The browser keeps a selected participant and an explicit follow preference
across a newer authorized observation of that same participant. In the model
this refines to `applyFrame` (which erases the old observation subject and its
work) followed by `select` of the new visible subject. It does not preserve the
old observation identity or its work reply. The work controller advances its
request generation before issuing the new observation-bound read; the
same-participant/new-observation race is a separate runtime test. Removal of
the participant or its visible position clears the participant selection too.

These are logical cleanup rules, not an instantaneous distributed revocation
claim. Database facts may change between reads or after a response is produced.
The runtime contract supplies event/heartbeat reauthorization and the client
deadline. The model assumes that current authority and consent facts passed to
its guards are authentic and faithfully resolved. It proves neither wall-clock
timing nor transaction isolation.

## 3. Selected work is a separate read

A work reply binds expected scope, local transport generation, work-request
epoch, participant and exact observation. The selected subject must still be
visible, the view must remain live, and separate load-read and assignment-read
authority must remain present. `mayShowWork` states the full admission predicate.
Selection changes, accepted replacement frames and clearing advance the local
epoch and erase old details. Aborting a fetch is a resource cleanup measure;
generation and subject checks supply the refusal even if it resolves late.

Theorems cover the successful authorized read and refusal after clear, scope
change, generation change, request replacement, changed selection and either
missing work capability. `frame_processing_preserves_business`,
`work_inspection_preserves_business`, `selection_preserves_business` and
`reconnect_preserves_business` prove that these modeled operations leave the
abstract business version unchanged.

The model does not infer an actual next stop from an ordered list of planned
stops, nor delivery from proximity. The runtime keeps progress unknown without
a separately accepted progress source. Assignment/load ownership joins,
selected record URLs, data minimization and absence of real database writes
require the concrete tests below.

## 4. What each verifier establishes

### Lean

The module contains 38 propositions quantified over arbitrary modeled natural
number identities, scopes, sequences, generations and observation lists.
`CheckDispatchSpatial.lean` adds 27 executable checks with both successful and
refused reads. Its compiled-module audit visits every declaration defined by
`BizKitDispatchSpatial`, requires key theorem declarations to exist, and permits
only Lean's standard `propext`, `Classical.choice` and `Quot.sound` axioms.
`sorryAx` and custom axioms fail that audit. The gate also replays the fresh
compiled module and its imports with `leanchecker --fresh`; this is a fresh
replay using the Lean kernel, not an independent kernel implementation.

The focused gate creates a new temporary Lake project from the inspected source
files. It neither restores project proof artifacts nor depends on unrelated
commercial model targets. The global `formal/lean/check.sh` still builds this
library and includes it in its own fresh replay and pinned axiom-audit run.

### Quint and Apalache

`formal/quint/dispatch_spatial.qnt` models two scopes, one participant, two actual
observation identities plus absence, three stream identities and cursors zero
through two. Safe-model reconnect generations stop at four; new work requests
are bounded by the work epoch. Watch membership is abstracted as one Boolean.
This is not a proof of multi-viewer watch reference counting.

The focused gate performs:

1. Typechecking of the specification, including every unsafe variant.
2. Eleven deterministic executable scenarios: nine client traces and two
   source traces. They witness visible live observations, accepted selected
   work, deletion, duplicate refusal without liveness renewal, scope/stream
   refusal, late-response refusal, capability revocation and reconnect fencing.
3. Seeded **sampled** exploration of each safe model: 1,000 traces with at most
   25 transitions, seed one. This is not exhaustive model checking.
4. Apalache bounded symbolic safety verification of each safe model through
   six transitions. No random-transition mode is used. A successful result
   establishes absence of invariant violations only within that model and bound.
5. Four deterministic unsafe runs. Each must exit with an invariant violation
   and produce an ITF trace containing its intended bad outcome. A parse error,
   type error, timeout, empty trace or unrelated tool failure does not count.

| Deliberately removed guard | Required counterexample |
| --- | --- |
| Scope equality | A visible observation from scope one remains on a page expecting scope zero |
| Strict cursor ordering | Sequence zero resurrects an observation after a sequence-one deletion |
| Work response fencing | A delayed work reply restores details after disconnection erased the page |
| Original consent identity | A replacement grant discloses the old grant's sample |

The deterministic successful traces make the refusal properties nonvacuous:
the model must actually admit an observation and work when authorized. The
counterexample checker inspects both Quint's violation status and the final
state in each generated trace.

## 5. Runtime refinement obligations

Paths below are relative to the repository root. Their tests must execute on
the same candidate as the models; this table does not claim that tests have
passed merely because their source exists.

| Obligation | Runtime sites | Concrete acceptance evidence |
| --- | --- | --- |
| Current selected authority, exact original consent and honest provenance | `apps/dispatch/lib/dispatch/operations/location_snapshot.ex` | `apps/dispatch/test/dispatch/operations/location_snapshot_test.exs`: explicit precise authority; revoked/renewed consent; expiry; participant organization/suspension; selected-role identity |
| Expected scope, fresh cursor lifetimes and scope-bound watches | `apps/dispatch/lib/dispatch_web/streams/locations.ex`, fleet map and location controllers | Snapshot tests for stable content revision, fresh GET IDs, SSE sequencing and no scope migration; `fleet_locations_controller_test.exs` for session logout and real stream cleanup |
| GET/SSE handoff, ordering, terminal refusal and liveness | `apps/dispatch/priv/static/js/maps/dispatch-map-feed.js` | `tools/dispatch-globe/test/feed.test.mjs`: old and duplicate events, nonzero first frames, wrong scope/stream, silent stream, failed reconnect and late fetch callbacks |
| Checked full replacement and honest incomplete coverage | `apps/dispatch/priv/static/js/maps/dispatch-map-model.js` and `location_snapshot.ex` | `tools/dispatch-globe/test/model.test.mjs` plus backend overflow, malformed uncertainty and encoded-response-budget cases |
| Exact sample-to-work join and separate capabilities | `apps/dispatch/lib/dispatch/operations/location_work.ex` | `apps/dispatch/test/dispatch/operations/location_work_test.exs`: missing either read capability, changed observations, consent renewal, revoked/narrowed authority and foreign carrier load |
| Late work, selection changes, timeout and capability loss | `apps/dispatch/priv/static/js/maps/dispatch-map-work.js` | `tools/dispatch-globe/test/work.test.mjs`: observation header, request generation, replacement/selection races, refusal and timeout |
| Erasure on all visible surfaces, local controls and no mutation | `dispatch-map.js`, `dispatch-map-renderer.js`, operator load controller | Actual browser selection/follow/filter and disconnect/late-response scenarios; backend unchanged business versions/statuses; independent operator-page authorization tests |
| Independent viewer demand cleanup | `LocationSnapshot` and `DispatchWeb.Streams.Locations` | Existing backend cases for watches added after opening, closing one viewer without ending another's watches, and source-session logout |

## 6. Reproduce and retain evidence

Install Lean with `formal/lean/install-toolchain.sh`; it verifies the project's
pinned archive. Install Quint 0.32.0 and use the digest-pinned
`tools/merchant_pilot/formal/install_apalache.sh` to create a new `QUINT_HOME`.
Java 17 or newer and Python 3 are needed. Put the pinned Lean and Quint binaries
on `PATH`, then run:

```sh
DISPATCH_SPATIAL_ARTIFACTS=/tmp/dispatch-spatial-models \
  bash formal/check_dispatch_spatial.sh
```

The gate checks Lean 4.35.0, Quint 0.32.0 and Apalache 0.56.1. It records a source
hash manifest, toolchain identities, per-check timing, Lean build/kernel/audit
logs, Quint test/simulation/verification logs and four negative ITF traces.
Retain that directory as CI evidence. The full existing proof suites remain
available through `formal/lean/check.sh` and `formal/quint/check.sh`.

These artifacts do not prove Elixir/Ash or PostgreSQL semantics, browser parser
correctness, SHA-256 collision resistance, HTTP transport, timer delivery,
Cesium rendering, sensor truth, physical-device collection, external provider
availability or production deployment. They define and check the abstract
contract whose concrete correspondence the runtime acceptance must establish.
