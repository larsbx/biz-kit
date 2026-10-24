defmodule InventoryCore.WireTest do
  use ExUnit.Case, async: true

  alias InventoryCore.Wire

  @scope %{"merchant" => "workshop", "item" => "part", "unit" => "each"}

  defp payload(op, attrs) do
    Map.merge(
      %{
        "schema" => "bizkit.inventory.command.v1",
        "merchant" => "workshop",
        "item" => "part",
        "unit" => "each",
        "id" => "command-1",
        "expected_version" => 0,
        "op" => op
      },
      attrs
    )
  end

  test "a host-scoped stock receipt is parsed without granting any authority" do
    input = payload("receive", %{"location" => "van", "quantity" => 4})

    assert {:ok, command} = Wire.decode(input, @scope)
    assert command == %{
             id: "command-1",
             expected_version: 0,
             op: :receive,
             location: "van",
             quantity: 4
           }

    {:ok, stock} = InventoryCore.new("workshop", "part", "each")
    assert {:ok, next, :accepted} = InventoryCore.apply(stock, "workshop", command)
    assert next.locations["van"] == 4
  end

  test "reservation and transfer commands remain serializable and scoped" do
    reserve =
      payload("reserve", %{
        "location" => "van",
        "quantity" => 2,
        "reservation_id" => "order-hold",
        "expires_at_ms" => 12_000
      })

    assert {:ok, %{op: :reserve, reservation_id: "order-hold"}} =
             Wire.decode(reserve, @scope)

    transfer = payload("transfer", %{"from" => "warehouse", "to" => "van", "quantity" => 5})
    assert {:ok, %{op: :transfer, from: "warehouse", to: "van"}} =
             Wire.decode(transfer, @scope)
  end

  test "tenant and stock-unit spoofing are refused before parsing a command" do
    input = payload("receive", %{"location" => "van", "quantity" => 4})

    assert {:error, :wrong_inventory_scope} =
             Wire.decode(%{input | "merchant" => "another"}, @scope)

    assert {:error, :wrong_inventory_scope} =
             Wire.decode(%{input | "unit" => "kilogram"}, @scope)

    assert {:error, :wrong_inventory_scope} =
             Wire.decode(input, %{"merchant" => "workshop", "item" => "part"})
  end

  test "unknown fields, atom keys and executable privilege assertions are refused" do
    input = payload("receive", %{"location" => "van", "quantity" => 4})

    assert {:error, :invalid_inventory_shape} =
             Wire.decode(Map.put(input, "approved", true), @scope)

    assert {:error, :invalid_inventory_shape} =
             Wire.decode(Map.put(input, :location, "van"), @scope)

    assert {:error, :unsupported_inventory_operation} =
             Wire.decode(%{input | "op" => "adjust"}, @scope)

    assert {:error, :unsupported_inventory_operation} =
             Wire.decode(%{input | "op" => "expire"}, @scope)
  end

  test "strict version and positive exact-unit bounds avoid JSON number ambiguity" do
    input = payload("receive", %{"location" => "van", "quantity" => 4})

    for quantity <- [0, -1, 1.5, "4", 9_007_199_254_740_992] do
      assert {:error, :invalid_inventory_value} =
               Wire.decode(%{input | "quantity" => quantity}, @scope)
    end

    assert {:error, :invalid_inventory_value} =
             Wire.decode(%{input | "expected_version" => -1}, @scope)

    assert {:error, :invalid_inventory_shape} =
             Wire.decode(%{input | "schema" => "bizkit.inventory.command.v2"}, @scope)
  end
end
