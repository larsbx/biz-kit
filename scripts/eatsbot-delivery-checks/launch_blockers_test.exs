defmodule RestaurantHost.LaunchBlockersTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias RestaurantHost.{Orders, World}

  @endpoint RestaurantHost.Web.Endpoint
  @basket %{"margherita" => 1}
  @delivery %{address: "1 Synthetic Test Lane"}

  test "delivery checkout stays closed with a grant and no Dispatch service" do
    ctx = World.build(delivery: %{fee_minor: 399}, transport: true)
    {:ok, store, _html} = live(build_conn(), "/")
    store |> element("#add-margherita") |> render_click()

    # Evaluate both paths even when the current implementation exposes checkout.
    observed = {
      has_element?(store, "#fulfillment-delivery"),
      Orders.place(ctx.restaurant, @basket, "Synthetic", "launch-probe", @delivery)
    }

    assert observed == {false, {:error, :delivery_unavailable}}
    assert Orders.list(ctx.restaurant) == []
  end

  test "baseline: signed pickup arriving after cancellation is refused" do
    ctx = World.build(delivery: %{fee_minor: 399}, transport: true)
    r = ctx.restaurant
    {:ok, order_id} = Orders.place(r, @basket, "Synthetic", "pickup-probe", @delivery)

    conn = get(build_conn(), "/board/pair/board-1/#{ctx.secret}")
    {:ok, board, _html} = live(recycle(conn), "/board")

    for action <- ~w(accept start_preparing mark_ready request_transport) do
      board |> element("##{action}-#{order_id}") |> render_click()
    end

    assert :ok = World.transport(ctx, order_id, "accept")
    assert %{state: :ready, handoff: %{view: :accepted}} = Orders.get(r, order_id)
    assert {:ok, :pending} = Orders.cancel(r, "board-1", order_id, "synthetic withdrawal")

    # Simulates delivery of a report after the food has already changed hands.
    # V1 has no distinct event for a verified observation of physical custody.
    assert {:error, :cancel_pending} = World.transport(ctx, order_id, "in_transit")
    assert %{state: :ready, handoff: %{view: :cancel_pending}} = Orders.get(r, order_id)
    IO.puts("DELIVERY_BLOCKER delayed_pickup_observation_unrepresented")
  end
end
