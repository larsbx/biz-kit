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
checks its shape and that it adds up (Pricing's I₂: each line discount within
its line, subtotal and total exact), so this layer (and the substrate that
admits it) never loads the money stack. `CoopSubstrate` registers these types in its Log:
`apps/coop_substrate/test/restaurant_admission_test.exs` shows eight concurrent
copies of one checkout place one order, ungranted devices append nothing, and
an order's history replays to its live state.

Depends only on `order_core` (resolved as a sibling, in or out of the umbrella).

```sh
cd apps/restaurant_core && mix test --no-start
```
