# The devices were enrolled over HTTP by the operator-side release command.
# Exercise their grants on the authoritative production writer.
alias CoopSubstrate.ULID
alias RestaurantHost.{Orders, Restaurant}

r = Restaurant.current()
{:ok, id} = Orders.place(r, %{"margherita" => 2}, "Smoke", ULID.generate())

for {action, version} <- Enum.with_index([:accept, :start_preparing, :mark_ready, :complete]),
    do: :ok = Orders.step(r, "board-1", id, action, version)

%{state: :completed, version: 4, total: 2650} = Orders.get(r, id)

# The release carries the delivery handoff and routes its types through
# RestaurantCore.Admission; no transport key exists here, so no driver moves.
true = Code.ensure_loaded?(FulfillmentCore) and Code.ensure_loaded?(OrderCore.Transport)
{:error, :not_a_delivery_order} = Orders.request_transport(r, "board-1", id, 4)
IO.puts("SMOKE OK #{id}")
