# RestaurantCore

The restaurant layer over [CommerceCore's order core](../commerce_core/README.md).
`RestaurantCore.Kitchen` binds `CommerceCore.OrderLifecycle` to a kitchen's
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

`new_checkout/2` opens a `CommerceCore.Checkout` projection over the same
workflow, so checkout offers delivery, pickup and dine-in and nothing else.

`test/kitchen_checkout_safety_test.exs` replays the 11 pinned checkout scenarios
(`checkout.jsonl`) through it unchanged. `test/kitchen_safety_test.exs` pins the old eatsbot's order fixtures
(`order_transitions` 192, `order_lifecycle` 38, `order_actions` 714 records,
sha256-pinned to `larsbx/eatsbot@15a201e`). All 48 recorded successes are
preserved, all 459 unauthorized requests uniformly refuse, and the other 207 get
typed refusals. See [the compatibility record](../../docs/architecture/2026-10-31-eatsbot-safety-compatibility.md).

Umbrella only: it depends on CommerceCore in the umbrella.

```sh
cd apps/restaurant_core && mix test --no-start
```
