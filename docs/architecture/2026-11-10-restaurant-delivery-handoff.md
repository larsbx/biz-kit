# Restaurant delivery handoff — 2026-11-10

Eatsbot rebuild slice 5: a delivery order is handed to Dispatch through
FulfillmentCore, and drivers use the d-patch app. This slice builds the
restaurant's side and the ledger rules; Dispatch's side (a service holding the
transport key, the d-patch integration, an ingress for its steps) is deferred,
so **delivery stays off on a deployed host**.

Gate (owner): I8 over every pair of states, and proof-backed completion and
failure. I8: a delivery order's transport states come only from Dispatch, its
kitchen states only from the restaurant.

## Decision

The order and its handoff live side by side in `gate.restaurant`, so every
admitted event moves the (order state, handoff view) pair in one fold. The
substrate routes the four new types to `RestaurantCore.Admission` by the
registration it already derives; its one library change is that
`RoleKeyDeclared` refuses a Dispatch transport key (see Keys).

### The relation (`RestaurantCore.Coupling`)

A literal, call-free module. The handoff is a `FulfillmentCore` state seen as
one of 13 views: `none`, `requested`, `accepted`, `in_transit`, `withdrawn`
(cancel requested before acceptance), `cancel_pending` (after acceptance),
`cancel_in_transit`, `rejected`, `cancelled`, `cancelled_in_transit`,
`delivered`, `failed_before_pickup`, `failed_in_transit`.

19 of the 104 delivery pairs are coupled:

| Order state | Views |
| --- | --- |
| placed, accepted, preparing | none |
| ready | none, requested, accepted, withdrawn, cancel_pending, rejected, cancelled, failed_before_pickup |
| dispatched | in_transit |
| completed | delivered |
| failed | failed_in_transit |
| cancelled | none, withdrawn, rejected, cancelled, failed_before_pickup |

30 joint steps (`rows/0`) join them, each `{from, owner, op, to, order_effect}`:

- **Restaurant, 17 rows.** 11 kitchen steps (accept, start preparing, mark
  ready; cancel from 8 pairs), 4 requests (from `ready` with no handoff, or one
  Dispatch rejected, cancelled or failed before pickup: `requestable/0`),
  2 withdrawals (`requested → withdrawn`, `accepted → cancel_pending`). The
  order moves only by `Kitchen.apply/3`.
- **Dispatch, 13 rows.** `accept`, `reject`, `cancel_confirmed` and `failed`
  before pickup hold the order; `in_transit` takes `ready → dispatched`,
  `delivered` takes `dispatched → completed`, `failed` in transit takes
  `dispatched → failed`, through `OrderCore.Transport`.

`RestaurantCore.Delivery` runs only the reducers a row names and admits only
the row's target pair. By induction from `(placed, none)`, the folded pair is
coupled after every admitted event.

**Stricter than the pinned reducers** (`strict/0`), each a loosening for later
that rejects no admitted history:

| Cell | FulfillmentCore or Kitchen alone | Admission |
| --- | --- | --- |
| kitchen cancel at (ready, requested / accepted / cancel_pending) | accepts | `:transport_pending` |
| restaurant withdrawal at (dispatched, in_transit) | accepts | `:transport_started` |
| Dispatch `in_transit` at (ready, cancel_pending) | accepts | `:cancel_pending` |
| Dispatch `accept` at (cancelled, withdrawn) | accepts | `:order_cancelled` |

### Refinement of the owner's lifecycle table: dispatched at pickup

The table reads "ready → dispatched: Dispatch, through a FulfillmentCore
request then Dispatch acceptance". Here the order becomes `dispatched` at
Dispatch's pickup fact (`in_transit`), which needs a prior admitted acceptance.
This is forced by the sha-pinned lifecycle: it has no `dispatched → cancelled`
and no `ready → failed`, so under dispatched-at-acceptance neither a
cancellation Dispatch confirms after acceptance (the table's own rule) nor a
failure before pickup would have a legal order edge. The legacy coupling
(`FulfillmentCore.OrderCoupling`, `In_Delivery`), `FulfillmentCore`'s
`transport_started`, `DispatchCore.LastMile` and the Quint candidate all tie
dispatch to pickup. The table's intent stands: eatsbot only requests, only
Dispatch accepts, nothing dispatches without an acceptance.

### Cancellation: two-phase

The order cancel is always the restaurant's own `RestaurantOrderStepV1`
cancel; a Dispatch event never takes an order-owned edge. It is refused
`:transport_pending` while transport is live (`requested`, `accepted`,
`cancel_pending`). The board's Cancel withdraws a live request first
(`RestaurantTransportCancelRequestedV1`, FulfillmentCore's commerce cancel):

- before acceptance the handoff becomes `withdrawn`, transport is no longer
  live, and the board cancels the order at once. A late acceptance is refused
  `:order_cancelled`; Dispatch acknowledges with `reject` or `cancel_confirmed`;
- after acceptance it becomes `cancel_pending`, the order holds at `ready`, and
  pickup is refused `:cancel_pending` until Dispatch confirms (`cancelled`) or
  reports a failure before pickup. The board then says so and offers Cancel to
  finish; it offers no new driver request after a confirmed withdrawal, though
  the ledger would admit one. The guest sees "Cancellation requested"
  throughout;
- after pickup there is no cancel: the order is `dispatched` and the pinned
  lifecycle has no edge out of it but completion or failure.

An earlier design released a recorded restaurant command inside Dispatch's
confirmation, which made a Dispatch-signed event take an order-owned edge and
kept a trusted context in the gate. Two phases need neither.

**Accepted risk.** A driver who already has the food when a cancellation is
admitted after acceptance cannot record the pickup; Dispatch must confirm or
report failure, and moved goods are an off-ledger incident. Admitting pickup
during a pending cancellation (as a non-moving step) is a later loosening.

### Keys (`RestaurantTransportGrantedV1`)

Dispatch signs `RestaurantTransportStepV1` under the non-declarable role
`dispatch_transport` with a key that governance grants per merchant, bound to
a Dispatch identity (`dispatch_id`). A grant is refused `:key_not_separate`
when its key is any restaurant device's key, any declared role key (in any
chapter), or another identity's transport key, or its id collides with a
device grant's. The converse holds in either order: a device grant is refused
for a transport key, and `RoleKeyDeclared`
(`CoopSubstrate.Protocol.Validity`) refuses one too, so a governance rotation
that picks up the Dispatch key by mistake cannot make one seed sign both sides
of I8. Both new checks read only transport keys, which no earlier history
holds. After
acceptance only the accepting identity may sign the handoff's later steps.
Five independent barriers keep a restaurant seed from producing a Dispatch
fact: envelope role equality, the separate registry, separation at grant time,
the identity pin, and `OrderCore.Transport`, whose context no device grant can
produce.

The I8 claim is scoped to governance-granted keys: whoever holds a chapter's
governance key can grant a transport key, so for a delivery chapter that key
must stay with the coop's administrators, never on the restaurant server
(`docs/deploy.md`). Transport keys, like devices, are irrevocable in this
slice.

### Proof

`delivered` and `failed` each carry a 32-byte evidence digest; without one
the step is refused `:proof_required`, and a digest any admitted step has
already cited is refused `:proof_reused`, so one piece of evidence cannot close
two orders. The digest is the SHA-256 of the evidence bundle Dispatch retains
(with d-patch: the driver's signed status declaration and the digests of any
photo, signature or code). A timer, silence, GPS proximity or a bearer key is
never proof. The gate checks the signature, the key and uniqueness; it does
not check that the evidence exists. This is an attestation, not custody;
custody-backed proof (a receipt the gate looks up) is a named V2.

### Uncertainty holds the state

Dispatch's silence or uncertainty is no event: the pair holds at
`(ready, requested | accepted | cancel_pending)` or
`(dispatched, in_transit)`. No timer, host process or restaurant event can
complete or fail a delivery.

## Evidence

- `apps/order_core/test/transport_test.exs`: Transport takes exactly the three
  delivery-owned edges over 3 × 8 × 8 cases; authorization precedes inspection;
  the device and transport contexts are disjoint in both directions; histories
  that reach `ready` and then mix order actions with transport steps replay as
  lifecycle histories and never drop an earlier binding, so an order command
  retried after pickup is still a duplicate.
- `apps/restaurant_core/test/coupling_test.exs`: the 312 (fulfillment, state,
  view) triples, the 30 rows, closure, reachability, provenance against
  `OrderCoupling.order_edge_owner/2`, `view/1` totality over the 13 abstract
  FulfillmentCore states both actors reach, agreement with the reducers on
  every coupled pair and op except exactly the six strict cells, and parity:
  the Quint model's rows and its control's loosened cells are parsed from
  `restaurant_delivery.qnt` and must equal `rows/0` and `strict/0`.
- `apps/restaurant_core/test/delivery_admission_test.exs`:
  - breadth-first search over the real `check/2` and `fold/2` from a placed
    delivery order, with 15 events per state, reaches exactly the 19 coupled
    pairs and admits exactly the 30 rows; over the 285 representative cases
    the refusal tally is pinned and matches an independent Python model;
  - every uncoupled pair, injected for each fulfillment, admits nothing;
  - all 1,197 (pair, device, kitchen action, version skew) cases: a step's
    admission is `Kitchen.apply/3`'s outcome except the 6 cancels refused
    `:transport_pending`;
  - non-interference: no device key, under any role label, moves a delivery
    into a Dispatch state or view;
  - interleavings, weighted towards the steps the relation allows, with
    measured reach (every Dispatch op, pickup, delivery and failure in transit,
    exits from a pending withdrawal): the pair stays coupled, `Kitchen.replay/2`
    and `FulfillmentCore.replay/3` (proof digests included) equal the gate, and
    the accepting Dispatch never changes;
  - the identity pin on every op after acceptance, by either acceptance path;
    proof reuse refused across failure and delivery, orders, merchants and
    chapters; the proof field typed `:hash`; requesting needs `mark_ready` and
    withdrawing needs `cancel`; precedence for every new refusal.
- `apps/coop_substrate/test/restaurant_delivery_test.exs`: routing of all seven
  types, the full paths through `Log.append`, role refusal at the envelope,
  `RoleKeyDeclared` of a transport key refused for every declarable role, eight
  concurrent accepts admit one, races decided by the appender, replay equal to
  the live gate.
- `apps/restaurant_host/test/slice5_gate_test.exs`: the gate through the
  storefront and board LiveViews with Dispatch played by the test, the guest's
  view of a cancellation pending with Dispatch, and a snapshot whose delivery
  text is not text rendering blank rather than crashing the board.
- `formal/quint/obligations/restaurant_delivery.qnt` (the rows, with a control
  admitting the strict cells) and `restaurant_core.qnt` (the transport registry
  disjoint from devices and role keys, in either order): simulated, verified to
  depth 8 and 6, witnesses reachable, controls violated, and each separation
  guard alone load-bearing.
- History: an independent reviewer folded 3,000 random 40-event pre-slice
  histories (grants, placements, kitchen steps, every fulfillment, skewed
  versions, ungranted devices) through main's `Admission` and this one: no
  difference in any outcome or state.
- The release smoke asserts the built release routes the new types.
- Review: a single adversarial reviewer and a six-lens review workflow with
  skeptic verification; every confirmed finding is fixed above, and every
  mutant they showed surviving is now killed (table below).

### Mutation kill table

Each mutant was applied alone to the umbrella, its suite run with seed 0, and
the mutant reverted: 46 mutants, all killed. The eight marked *Review* are the
mutants the reviewers showed surviving an earlier version of the suite; the
identity-pin, proof-index, interleaving, refinement and order_core tests above
were strengthened until each fails. A first pass also found one survivor that
was a redundant check (the withdrawal clause's delivery check: a non-delivery
order never has a handoff, so the withdrawal is refused `:unknown_handoff`); it
was removed rather than pinned.

Quint: dropping any one separation guard in `restaurant_core.qnt` (device and
transport, either order; role key and transport, either order) violates its
obligation. The source coupling checks in `RestaurantCore.Delivery` are
equivalent mutants by design: a row exists only from a coupled pair, so they
fail closed ahead of the row lookup.

| Mutant | Killed by |
| --- | --- |
| Transport: authorization not first | 2 failing tests |
| Transport: any extra context key accepted | 2 failing tests |
| Transport: no delivery check | 1 failing test |
| Transport: no delivery-owned check | 1 failing test |
| Transport: no version check | 1 failing test |
| Transport: no legal? check | 2 failing tests |
| Transport: no reason on failed | 1 failing test |
| Transport: seen key not namespaced | 2 failing tests |
| Coupling: drop the (ready, rejected) request row | 3 failing tests |
| Coupling: K8 cancels into (cancelled, none) | 5 failing tests |
| Coupling: swap withdrawn and cancel_pending in view/1 | 9 failing tests |
| Coupling: failed before pickup merged into in transit | 7 failing tests |
| Coupling: cancel_pending not live | 3 failing tests |
| Coupling: admit pickup at cancel_pending | 3 failing tests |
| Coupling: admit accept at (cancelled, withdrawn) | 3 failing tests |
| Coupling: order moves at acceptance | 13 failing tests |
| Coupling: in_transit targets completed | 11 failing tests |
| Coupling: delivered needs no proof | 8 failing tests |
| Coupling: failed needs no proof | 9 failing tests |
| Delivery: transport effect does not move the order | 9 failing tests |
| Delivery: FulfillmentCore duplicate treated as new | 2 failing tests |
| Delivery: withdrawal signed as Dispatch | 8 failing tests |
| Delivery: request off ready | 2 failing tests |
| Delivery: request over a live handoff | 2 failing tests |
| Admission: transport signers looked up among device grants | 12 failing tests |
| Admission: separation, device key id | 1 failing test |
| Admission: separation, device pubkey | 1 failing test |
| Admission: separation, declared role keys | 1 failing test |
| Admission: separation, another Dispatch identity | 1 failing test |
| Admission: converse separation, transport key id | 1 failing test |
| Admission: converse separation, transport pubkey | 1 failing test |
| Admission: request id reuse not indexed | 1 failing test |
| Admission: request without transport authority | 1 failing test |
| Admission: request without an address | 1 failing test |
| Admission: Dispatch fields not exact | 1 failing test |
| Host: cancel without withdrawing | 3 failing tests |
| Host: delivery offered without a transport grant | 2 failing tests |
| Substrate: a role key may reuse a transport key | 1 failing test |
| Review M4: pin covers pickup and delivery only | 1 failing test |
| Review M3: acceptance from withdrawn sets no pin | 1 failing test |
| Review M1: failed-step proofs not indexed | 1 failing test |
| Review M2: proof index per merchant | 2 failing tests |
| Review: constant proof_ref to FulfillmentCore | 1 failing test |
| Review: transport_pending before authorization | 1 failing test |
| Review M8: Transport drops the order's bindings | 2 failing tests |
| Board renders a non-text address | 1 failing test |

## Deferred

- Dispatch's side: a service holding the transport seed, learning of requests
  only from the ledger feed, signing one step per decision with a stable
  `step_id`, retrying the identical envelope, treating `{:duplicate_transport_step, _}`
  as success, re-reading on `:stale_fulfillment_version`, and treating
  `:order_cancelled`, `:cancel_pending`, `:unknown_request`, `:forbidden` and
  `:terminal_fulfillment` as final. d-patch keeps signing its status
  declarations to Dispatch.
- Production enrolment of transport keys (a held-bytes grant flow as for
  devices), revocation and rotation.
- Custody-backed proof (`RestaurantTransportStepV2` citing an
  `ArtifactCustodyRecordedV1` receipt).
- Guest and timer-signed cancellation requests (a timer may only ever sign a
  request), an uncertainty or incident fact, requesting transport before
  `ready`, and admitting pickup during a pending cancellation.
- Delivery fee rules beyond one flat fee, refunds and settlement (Hawala's).
- No R-gate is closed by this slice.

## Owner questions

1. Ratify dispatched-at-pickup, and the pending cancellation blocking pickup.
2. The delivery address is signed onto the append-only ledger, in the placed
   event's existing optional `delivery` map. Acceptable, or an off-ledger
   store before production delivery?
3. Is a Dispatch-signed digest acceptable proof for launch, or must custody
   (V2) come first?
4. Cash on delivery: may drivers hold cash? Agree with Hawala and Dispatch
   before launch.
5. Who holds the governance key of a delivery chapter?
