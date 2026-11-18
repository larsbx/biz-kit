# OrderCore

The money-free order core. Pure; no dependencies.

* `OrderCore.Lifecycle`: the merchant-neutral order lifecycle and its
  authorized candidate reducer. `workflow/1` builds it from a merchant's
  production stages s₁ … sₙ:

      placed → accepted → s₁ … sₙ → completed          (non-delivery)
      sₙ → dispatched → completed | failed              (delivery; delivery-owned)
      {placed, accepted, s₁ … sₙ} → cancelled

  Authorization precedes every observation of state; scope, revision,
  idempotency, required reasons and delivery ownership are the core's.
* `OrderCore.Placement`: one order per cart, channel-scoped idempotency, cart
  ownership and the workflow's fulfillments. The priced snapshot is opaque:
  `CommerceCore.Checkout` prices with Money, and signed-log admission
  (`RestaurantCore.Admission`) records a device-signed snapshot in minor units.

Money is Hawala's: nothing here computes, accepts or settles an amount, and
every placed order is `financial_status: :unconfirmed`.

`test/lifecycle_test.exs` proves the lifecycle's shape, walk ≡ replay, delivery
ownership, authorization before observation, stage roles and replay refusal for
arbitrary stage lists. Placement is exercised through CommerceCore's checkout
tests and the restaurant admission tests.

```sh
cd apps/order_core && mix test --no-start
```
