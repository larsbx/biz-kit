# RestaurantHost

The rebuilt Eatsbot pickup MVP: a cash-only storefront and a
kitchen board, both Phoenix LiveView, with every order step admitted through
the signed Log (`CoopSubstrate.Log`, rule `RestaurantCore.Admission`).

    storefront (/)        price basket ─ sign RestaurantOrderPlacedV1 ─┐
                                                                       ├─▶ Log admits or refuses
    kitchen board (/board) sign RestaurantOrderStepV1 ─────────────────┘        │
                         ◀──────────── live view of what the Log holds ◀───────┘

* **Storefront.** Menu from a `CommerceCore.Catalog`, priced with `Tax` and
  `Pricing`. A customer can order as a guest or sign in through
  `BizKit.Identity` and see their own orders. Customers give a pickup name and
  pay cash at the counter. The host signs
  the priced snapshot with the storefront device (granted `checkout`). A
  repeated submit carries the same checkout key, so it returns the same order.
  The page then follows the order's state live.
* **Kitchen board.** Lists open orders with exactly the steps each can take
  now (`OrderCore.Lifecycle.available_actions/2`) and signs each with the
  board's own device key. A board acts only after pairing:
  `/board/pair/:board/:secret` compares the secret's SHA-256 in constant time
  and puts the board in the browser's signed session. If the operator
  configures staff principals, staff must also sign in. A governance-signed
  device revocation fences that key in the Log.
* **No state of its own.** Orders are read back from the Log's gate. No
  financial operation exists: money is Hawala's, and payment is cash.

Each device is a key that a governance grant (`RestaurantDeviceGrantedV1`) has
bound to the merchant. The host holds the device seeds. See [deployment and
operator commands](../../docs/deploy.md#the-restaurant-release).

## Tests

`test/slice4_gate_test.exs` is the slice gate: a pickup order is placed on the
web, accepted, prepared and completed on the board, and the guest's page shows
"Picked up". Each test builds its restaurant in a fresh Log chapter
(`RestaurantHost.World`), so the shared ledger needs no reset. Needs Postgres
for the Log's event store:

```sh
cd apps/restaurant_host
EVENTSTORE_USERNAME=postgres EVENTSTORE_PASSWORD=postgres mix test --no-start
```

`--no-start` matters: the test helper points Localize at its bundled English
locale before starting the host, because the umbrella's shared config points
it at the legacy eatsbot's locale cache.

## Pickup MVP boundaries

Customers and staff use prebound Biz-kit identities. Discounts are
merchant-funded, fixed amounts per item. Delivery remains slice 5 through
Dispatch and FulfillmentCore, and card payments belong to Hawala.
The release can be tested with an empty restaurant ledger before the
separate legacy cutover tracked in [#176](https://github.com/larsbx/biz-kit/issues/176).
