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
end
