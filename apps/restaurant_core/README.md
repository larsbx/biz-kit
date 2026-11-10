# RestaurantCore

The money-free restaurant layer over [the order core](../order_core/README.md).
`RestaurantCore.Kitchen` binds `OrderCore.Lifecycle` to a kitchen's
production stages and offers the core's API without the workflow argument:

    placed → accepted → preparing → ready → completed      (pickup, dine-in)
    ready → dispatched → completed | failed                (delivery; delivery-owned)
    {placed, accepted, preparing, ready} → cancelled

| Action | Stage | Roles |
| --- | --- | --- |
| `start_preparing` | `preparing` | admin, staff |
| `mark_ready` | `ready` | admin, staff |

Every other rule belongs to the core: authorization first, merchant/order scope,
revision, idempotency, required reasons and delivery ownership. This layer adds
none of its own.

Checkout takes the same workflow (`CommerceCore.Checkout.new(Kitchen.workflow(), …)`),
so it offers delivery, pickup and dine-in and nothing else; CommerceCore replays
the pinned checkout fixture that way. `test/kitchen_safety_test.exs` pins the old eatsbot's order fixtures
(`order_transitions` 192, `order_lifecycle` 38, `order_actions` 714 records,
sha256-pinned to `larsbx/eatsbot@15a201e`). All 48 recorded successes are
preserved, all 459 unauthorized requests uniformly refuse, and the other 207 get
typed refusals. See [the compatibility record](../../docs/architecture/2026-10-31-eatsbot-safety-compatibility.md).

`RestaurantCore.Admission` is the pure admission rule for signed restaurant
events, in the shape of `TaskCore.Admission`: a governance-signed
`RestaurantDeviceGrantedV1` binds a device key to a merchant, actor and actions;
`RestaurantOrderPlacedV1` and `RestaurantOrderStepV1`, signed by a granted
device, run `OrderCore.Placement` and `Kitchen.apply/3`. The trusted context
comes from the grant, never the payload, and `test/admission_test.exs` proves
admission refines the kitchen reducer (same outcome, same state, for any step
sequence).

Money is Hawala's. The device prices an order with `CommerceCore.Checkout`
before signing; admission records that snapshot in integer minor units and
checks only its shape, so this layer (and the substrate that admits it) never
loads the money stack. `CoopSubstrate` registers these types in its Log:
`apps/coop_substrate/test/restaurant_admission_test.exs` shows eight concurrent
copies of one checkout place one order, ungranted devices append nothing, and
an order's history replays to its live state.

## Delivery handoff

A delivery order is handed to Dispatch through a `FulfillmentCore` request.
`RestaurantCore.Coupling` states I8 as data: the handoff's 13 views
(`view/1` over FulfillmentCore's states), the 19 coupled
(order state, view) pairs, and the 30 joint steps (`rows/0`) between them, each
owned by the restaurant or by Dispatch. `RestaurantCore.Delivery` runs only the
reducers a row names (`Kitchen.apply/3`, `FulfillmentCore.apply/4`,
`OrderCore.Transport.apply/4`) and admits only the row's target.

| Event | Signed by | Effect |
| --- | --- | --- |
| `RestaurantTransportGrantedV1` | governance | binds a Dispatch transport key and identity to a merchant; it shares no key with any device or declared role key |
| `RestaurantTransportRequestedV1` | a device that may `mark_ready` | opens a request for a ready delivery order with an address |
| `RestaurantTransportCancelRequestedV1` | a device that may `cancel` | withdraws the request (FulfillmentCore's commerce cancel); the order holds |
| `RestaurantTransportStepV1` | `dispatch_transport`, a granted key; after acceptance only the accepting Dispatch | one Dispatch op: `accept`, `reject`, `in_transit`, `delivered`, `failed`, `cancel_confirmed` |

- **Dispatched at pickup.** `in_transit`, after an admitted acceptance, takes
  `ready → dispatched`; `delivered` and `failed` take `dispatched → completed | failed`,
  through `OrderCore.Transport`. The pinned lifecycle has no
  `dispatched → cancelled` and no `ready → failed`, so an accepted order stays
  `ready` until pickup.
- **Proof.** `delivered` and `failed` each carry a 32-byte evidence digest that
  no admitted step has cited before. It is an attestation by Dispatch's key, not
  custody of the evidence.
- **Cancellation is two-phase.** The order cancel is always the kitchen's own
  step, refused `:transport_pending` while transport is live (requested,
  accepted, or a withdrawal Dispatch has not resolved). Before Dispatch accepts,
  a withdrawal ends that at once; after, the withdrawal is pending until Dispatch
  confirms or reports a failure before pickup, and a pending withdrawal blocks
  pickup (`:cancel_pending`). After pickup there is no cancel. Dispatch never
  takes an order-owned edge and the restaurant never a delivery-owned one.
- **Silence holds.** No timer and no restaurant event completes or fails a
  delivery.

`Coupling.strict/0` names the six cells the pinned reducers would accept but
admission refuses; each can be loosened later without rejecting admitted
history. `test/coupling_test.exs` checks the relation against the reducers on
every pair and step; `test/delivery_admission_test.exs` searches the real
`check/2` and `fold/2` breadth-first (the reached pairs are the coupled pairs,
the admitted steps are the rows, 285 cases with a pinned refusal tally), injects
every uncoupled pair, and checks interleavings against
`FulfillmentCore.replay/3` and `Kitchen.replay/2`. See
[the ADR](../../docs/architecture/2026-11-10-restaurant-delivery-handoff.md).

Depends on `order_core` and `fulfillment_core` (resolved as siblings, in or out
of the umbrella).

```sh
cd apps/restaurant_core && mix test --no-start
```
