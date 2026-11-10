defmodule RestaurantHost.OrdersTest do
  use ExUnit.Case, async: false

  alias RestaurantHost.{Orders, World}

  setup do: {:ok, World.build()}

  defp minor(m), do: m |> Money.to_integer_exp() |> elem(1)

  test "a basket is priced from the catalog with sales tax", %{restaurant: r} do
    {:ok, priced} = Orders.price(r, %{"margherita" => 2, "pepperoni" => 1})

    assert Enum.map(priced.lines, &{&1.item_id, &1.quantity, minor(&1.subtotal)}) ==
             [{"margherita", 2, 2500}, {"pepperoni", 1, 1400}]

    # Michigan: 6% of 39.00 is 2.34.
    assert {minor(priced.subtotal), minor(priced.tax), minor(priced.total)} == {3900, 234, 4134}
    assert Orders.price(r, %{"calzone" => 1}) == {:error, :unknown_item}
  end

  test "placing signs the priced snapshot; the same checkout key returns the same order", %{
    restaurant: r
  } do
    {:ok, id} = Orders.place(r, %{"margherita" => 2}, "Ada", "key-1")
    assert {:ok, ^id} = Orders.place(r, %{"margherita" => 2}, "Ada", "key-1")

    assert [%{id: ^id, state: :placed, pickup_name: "Ada", total: 2650, fulfillment: :pickup}] =
             Orders.list(r)

    assert Orders.place(r, %{}, "Ada", "key-2") == {:error, :no_lines}

    assert Orders.place(r, %{"margherita" => 1}, "", "key-3") ==
             {:error, :invalid_checkout_command}

    assert length(Orders.list(r)) == 1
  end

  test "a paired board walks a pickup order to completion; nothing else can", %{restaurant: r} do
    {:ok, id} = Orders.place(r, %{"pepperoni" => 1}, "Grace", "key-1")
    assert Orders.step(r, "board-9", id, :accept, 0) == {:error, :forbidden}

    for {action, v} <- Enum.with_index([:accept, :start_preparing, :mark_ready, :complete]) do
      assert Orders.step(r, "board-1", id, action, v) == :ok
    end

    assert %{state: :completed, version: 4, actions: []} = Orders.get(r, id)
    assert Orders.step(r, "board-1", id, :cancel, 4, "too late") == {:error, :invalid_transition}
  end

  test "a delivery basket adds the restaurant's fee, itemized and untaxed under US-MI" do
    %{restaurant: r} = World.build(delivery: %{fee_minor: 399})
    {:ok, pickup} = Orders.price(r, %{"margherita" => 2})
    {:ok, delivery} = Orders.price(r, %{"margherita" => 2}, :delivery)

    assert {minor(pickup.tax), minor(pickup.adjustments.delivery_fee), minor(pickup.total)} ==
             {150, 0, 2650}

    assert {minor(delivery.tax), minor(delivery.adjustments.delivery_fee), minor(delivery.total)} ==
             {150, 399, 3049}

    assert Orders.price(World.build().restaurant, %{"margherita" => 2}, :delivery) ==
             {:error, :delivery_unavailable}
  end

  test "delivery is offered only with a delivery section and a transport grant, to an address" do
    refute Orders.delivery?(World.build().restaurant)
    refute Orders.delivery?(World.build(delivery: %{fee_minor: 399}).restaurant)

    %{restaurant: r} = World.build(transport: true)
    refute Orders.delivery?(r)

    assert Orders.place(r, %{"margherita" => 1}, "Ada", "k1", %{address: "1 Main St"}) ==
             {:error, :delivery_unavailable}

    %{restaurant: r} = World.build(delivery: %{fee_minor: 399}, transport: true)
    assert Orders.delivery?(r)

    for bad <- [
          %{address: ""},
          %{address: "   "},
          %{address: String.duplicate("a", 201)},
          %{address: "1 Main St", notes: String.duplicate("n", 201)},
          %{}
        ],
        do:
          assert(
            Orders.place(r, %{"margherita" => 1}, "Ada", "k1", bad) == {:error, :invalid_address}
          )

    {:ok, id} =
      Orders.place(r, %{"margherita" => 2}, "Ada", "k1", %{
        address: " 1 Main St ",
        notes: "ring twice"
      })

    assert %{
             fulfillment: :delivery,
             total: 3049,
             delivery: %{"address" => "1 Main St", "notes" => "ring twice"}
           } =
             Orders.get(r, id)

    {:ok, id} =
      Orders.place(r, %{"margherita" => 2}, "Ada", "k2", %{address: "2 Main St", notes: ""})

    assert Orders.get(r, id).delivery == %{"address" => "2 Main St"}
  end

  test "a board requests a driver, and cancels by withdrawing it first" do
    %{restaurant: r} = ctx = World.build(delivery: %{fee_minor: 399}, transport: true)

    ready = fn key ->
      {:ok, id} = Orders.place(r, %{"margherita" => 1}, "Ada", key, %{address: "1 Main St"})

      for {action, v} <- Enum.with_index([:accept, :start_preparing, :mark_ready]),
          do: :ok = Orders.step(r, "board-1", id, action, v)

      id
    end

    {:ok, pickup} = Orders.place(r, %{"margherita" => 1}, "Grace", "kp")
    assert Orders.request_transport(r, "board-1", pickup, 0) == {:error, :not_a_delivery_order}

    id = ready.("k1")
    assert Orders.request_transport(r, "board-9", id, 3) == {:error, :forbidden}
    assert Orders.request_transport(r, "board-1", id, 2) == {:error, :stale_order_version}
    assert Orders.request_transport(r, "board-1", id, 3) == :ok

    assert %{handoff: %{view: :requested}, handoff_actions: [:withdraw_transport], actions: []} =
             Orders.get(r, id)

    assert Orders.cancel(r, "board-1", id, "customer called") == :ok
    assert %{state: :cancelled, handoff: %{view: :withdrawn}} = Orders.get(r, id)

    id = ready.("k2")
    :ok = Orders.request_transport(r, "board-1", id, 3)
    World.transport!(ctx, id, "accept")
    assert Orders.cancel(r, "board-1", id, "customer called") == {:ok, :pending}
    assert %{state: :ready, handoff: %{view: :cancel_pending}, actions: []} = Orders.get(r, id)
    assert Orders.cancel(r, "board-1", id, "again") == {:ok, :pending}
    World.transport!(ctx, id, "cancel_confirmed")

    assert %{
             handoff: %{view: :cancelled},
             handoff_actions: [],
             actions: [:cancel]
           } = Orders.get(r, id)

    assert Orders.cancel(r, "board-1", id, "customer called") == :ok
    assert %{state: :cancelled} = Orders.get(r, id)
  end
end
