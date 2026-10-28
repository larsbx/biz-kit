defmodule InventoryCoreTest do
  use ExUnit.Case, async: true

  defp empty(merchant), do: elem(InventoryCore.new(merchant, "item", "each"), 1)

  defp command(state, id, op, attrs) do
    Map.merge(%{id: id, expected_version: state.version, op: op}, attrs)
  end

  defp accepted(state, merchant, id, op, attrs) do
    {:ok, updated, :accepted} =
      InventoryCore.apply(state, merchant, command(state, id, op, attrs))

    updated
  end

  test "holds prevent overselling and repeat admission is idempotent" do
    state = empty("restaurant")
    state = accepted(state, "restaurant", "r1", :receive, %{location: "walk-in", quantity: 10})

    hold =
      command(state, "h1", :reserve, %{
        location: "walk-in",
        quantity: 8,
        reservation_id: "customer-1",
        expires_at_ms: 1_000
      })

    {:ok, state, :accepted} = InventoryCore.apply(state, "restaurant", hold)
    assert {:ok, state, :duplicate} = InventoryCore.apply(state, "restaurant", hold)
    assert {:ok, 2} = InventoryCore.available(state, "restaurant", "walk-in")

    assert {:error, :insufficient_available} =
             InventoryCore.apply(
               state,
               "restaurant",
               command(state, "h2", :reserve, %{
                 location: "walk-in",
                 quantity: 3,
                 reservation_id: "customer-2",
                 expires_at_ms: 2_000
               })
             )

    assert {:error, :stale_stock_version} =
             InventoryCore.apply(state, "restaurant", %{hold | id: "different"})
  end

  test "partial commits consume only held stock and release the remainder" do
    state = empty("restaurant")
    state = accepted(state, "restaurant", "r", :receive, %{location: "fridge", quantity: 12})

    state =
      accepted(state, "restaurant", "h", :reserve, %{
        location: "fridge",
        quantity: 8,
        reservation_id: "hold",
        expires_at_ms: 50
      })

    state = accepted(state, "restaurant", "c", :commit, %{reservation_id: "hold", quantity: 3})
    assert state.locations["fridge"] == 9
    assert {:ok, 4} = InventoryCore.available(state, "restaurant", "fridge")
    state = accepted(state, "restaurant", "l", :release, %{reservation_id: "hold"})
    assert {:ok, 9} = InventoryCore.available(state, "restaurant", "fridge")
    assert :ok = InventoryCore.check(state, "restaurant")
  end

  test "transfer is atomic within one stock aggregate and cannot take reserved stock" do
    state = empty("workshop")
    state = accepted(state, "workshop", "r", :receive, %{location: "warehouse", quantity: 7})

    state =
      accepted(state, "workshop", "h", :reserve, %{
        location: "warehouse",
        quantity: 5,
        reservation_id: "repair-job",
        expires_at_ms: 100
      })

    assert {:error, :insufficient_available} =
             InventoryCore.apply(
               state,
               "workshop",
               command(state, "bad", :transfer, %{
                 from: "warehouse",
                 to: "van",
                 quantity: 3
               })
             )

    state =
      accepted(state, "workshop", "ok", :transfer, %{
        from: "warehouse",
        to: "van",
        quantity: 2
      })

    assert state.locations == %{"warehouse" => 5, "van" => 2}
    assert {:ok, 0} = InventoryCore.available(state, "workshop", "warehouse")
  end

  test "expiry releases holds exactly once and refuses clock reversal" do
    state = empty("restaurant")
    state = accepted(state, "restaurant", "r", :receive, %{location: "store", quantity: 2})

    state =
      accepted(state, "restaurant", "h", :reserve, %{
        location: "store",
        quantity: 2,
        reservation_id: "expires",
        expires_at_ms: 5
      })

    state = accepted(state, "restaurant", "tick", :expire, %{at_ms: 5})
    assert {:ok, 2} = InventoryCore.available(state, "restaurant", "store")

    assert {:error, :nonmonotone_clock} =
             InventoryCore.apply(
               state,
               "restaurant",
               command(state, "past", :expire, %{at_ms: 4})
             )

    assert {:error, :reservation_not_active} =
             InventoryCore.apply(
               state,
               "restaurant",
               command(state, "late", :commit, %{reservation_id: "expires", quantity: 1})
             )
  end

  test "scope, mutation ID reuse and adjustment approval all fail closed" do
    state = empty("workshop")
    receive = command(state, "id", :receive, %{location: "bay", quantity: 5})

    assert {:error, :wrong_merchant} = InventoryCore.apply(state, "restaurant", receive)
    {:ok, state, :accepted} = InventoryCore.apply(state, "workshop", receive)

    assert {:error, :idempotency_conflict} =
             InventoryCore.apply(state, "workshop", %{receive | quantity: 6})

    assert {:error, :invalid_or_unauthorized_operation} =
             InventoryCore.apply(
               state,
               "workshop",
               command(state, "adjust", :adjust, %{
                 location: "bay",
                 delta: -2,
                 reason: "audit",
                 approved: false
               })
             )

    assert {:error, :insufficient_available} =
             InventoryCore.apply(
               state,
               "workshop",
               command(state, "shrink", :adjust, %{
                 location: "bay",
                 delta: -6,
                 reason: "audit",
                 approved: true
               })
             )
  end

  test "deterministic replay gives the same stock and reservation state" do
    initial = empty("restaurant")

    a = command(initial, "a", :receive, %{location: "store", quantity: 10})
    {:ok, first, :accepted} = InventoryCore.apply(initial, "restaurant", a)

    b =
      command(first, "b", :reserve, %{
        location: "store",
        quantity: 4,
        reservation_id: "takeout",
        expires_at_ms: 100
      })

    {:ok, state} = InventoryCore.replay(initial, "restaurant", [a, b, b])
    assert state.version == 2
    assert state.locations["store"] == 10
    assert state.reservations["takeout"].remaining == 4
    assert :ok = InventoryCore.check(state, "restaurant")
  end
end
