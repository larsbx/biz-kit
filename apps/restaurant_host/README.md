# RestaurantHost

The rebuilt eatsbot's host (rebuild slice 4): a cash-only storefront and a
kitchen board, both Phoenix LiveView, with every order step admitted through
the signed Log (`CoopSubstrate.Log`, rule `RestaurantCore.Admission`).

    storefront (/)        price basket ─ sign RestaurantOrderPlacedV1 ─┐
                                                                       ├─▶ Log admits or refuses
    kitchen board (/board) sign RestaurantOrderStepV1 ─────────────────┘        │
                         ◀──────────── live view of what the Log holds ◀───────┘

* **Storefront.** Menu from a `CommerceCore.Catalog`, priced with `Tax` and
  `Pricing`; the guest gives a name and pays cash at pickup. The host signs
  the priced snapshot with the storefront device (granted `checkout`). A
  repeated submit carries the same checkout key, so it returns the same order.
  The page then follows the order's state live.
* **Kitchen board.** Lists open orders with exactly the steps each can take
  now (`OrderCore.Lifecycle.available_actions/2`) and signs each with the
  board's own device key. A board acts only after pairing:
  `/board/pair/:board/:secret` compares the secret's SHA-256 in constant time
  and puts the board in the browser's signed session.
* **No state of its own.** Orders are read back from the Log's gate. No
  financial operation exists: money is Hawala's, and payment is cash.

Each device is a key that a governance grant (`RestaurantDeviceGrantedV1`) has
bound to the merchant; the host holds the device seeds. Moving signing onto
the devices themselves, and staff sign-in, are later slices.

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

## Not yet

* Revoking a device's grant. Deploying, and granting devices with
  `mix restaurant.grant`, are described in
  [docs/deploy.md](../../docs/deploy.md#the-restaurant-release).
* Grant revocation, staff sign-in, cancellation reasons chosen at the board,
  receipt printing, delivery (slice 5) and card payments through Hawala.
* Editing the menu and its discounts without a restart (decommission D6):
  today both come from the restaurant file.

## Discounts

A menu item may list discount rules (`CommerceCore.Discounts`; format in
`RestaurantHost.Config` and [docs/deploy.md](../../docs/deploy.md#the-restaurant-release)).
The storefront gives each line the single best rule that applies at the
restaurant's local time (`timezone`, IANA, default UTC), taxes the discounted
amount, shows the discount, and signs the line with the rule's id
(`discount_rule`).
