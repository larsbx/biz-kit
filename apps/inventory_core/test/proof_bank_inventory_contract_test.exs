defmodule InventoryCore.ProofBankArithmeticTest do
  @moduledoc """
  Conformance probes for the single-location arithmetic fragment modeled in
  formal/lean/BizKitInventory.lean. Tests use the real InventoryCore.apply/3,
  not a simulated copy of the Elixir transition implementation.

  This is bounded test evidence. It is NOT a proof of implementation
  refinement, host serialization, tenant authorization, or basket atomicity.
  """
  use ExUnit.Case, async: true

  defp command(stock, id, op, args) do
    Map.merge(%{id: id, expected_version: stock.version, op: op}, args)
  end

  defp initial_stock(on_hand) do
    {:ok, initial} = InventoryCore.new("merchant", "part", "each")

    if on_hand == 0 do
      initial
    else
      {:ok, received, :accepted} =
        InventoryCore.apply(
          initial,
          "merchant",
          command(initial, "receive", :receive, %{location: "shelf", quantity: on_hand})
        )

      received
    end
  end

  test "single-location abstract reserve guard agrees with actual apply for bounded exact integers" do
    for on_hand <- 0..15, requested <- 1..16 do
      stock = initial_stock(on_hand)

      reserve =
        command(stock, "hold", :reserve, %{
          location: "shelf",
          quantity: requested,
          reservation_id: "hold-id",
          expires_at_ms: 100
        })

      if requested <= on_hand do
        assert {:ok, held, :accepted} = InventoryCore.apply(stock, "merchant", reserve)
        assert :ok = InventoryCore.check(held, "merchant")
        assert {:ok, available} = InventoryCore.available(held, "merchant", "shelf")
        assert available == on_hand - requested
        assert {:ok, ^held, :duplicate} = InventoryCore.apply(held, "merchant", reserve)
        assert held.version == stock.version + 1

        for committed_qty <- 1..requested do
          commit =
            command(held, "commit", :commit, %{
              reservation_id: "hold-id",
              quantity: committed_qty
            })

          assert {:ok, committed, :accepted} = InventoryCore.apply(held, "merchant", commit)
          assert :ok = InventoryCore.check(committed, "merchant")
          assert committed.locations["shelf"] == on_hand - committed_qty
          assert committed.reservations["hold-id"].remaining == requested - committed_qty
          assert {:ok, ^available} = InventoryCore.available(committed, "merchant", "shelf")
        end

        release = command(held, "release", :release, %{reservation_id: "hold-id"})
        assert {:ok, released, :accepted} = InventoryCore.apply(held, "merchant", release)
        assert :ok = InventoryCore.check(released, "merchant")
        assert {:ok, ^on_hand} = InventoryCore.available(released, "merchant", "shelf")
      else
        assert {:error, :insufficient_available} =
                 InventoryCore.apply(stock, "merchant", reserve)
      end
    end
  end

  test "failed operations have no accepted successor and a changed retry cannot reuse a command ID" do
    stock = initial_stock(2)

    bad =
      command(stock, "over", :reserve, %{
        location: "shelf",
        quantity: 3,
        reservation_id: "r1",
        expires_at_ms: 100
      })

    assert {:error, :insufficient_available} = InventoryCore.apply(stock, "merchant", bad)

    good = %{bad | quantity: 2}
    assert {:ok, held, :accepted} = InventoryCore.apply(stock, "merchant", good)
    assert {:error, :idempotency_conflict} = InventoryCore.apply(held, "merchant", bad)

    stale = command(stock, "other", :receive, %{location: "shelf", quantity: 1})
    assert {:error, :stale_stock_version} = InventoryCore.apply(held, "merchant", stale)
    assert :ok = InventoryCore.check(held, "merchant")
  end
end
