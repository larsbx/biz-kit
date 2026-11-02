defmodule CoopSubstrate.RestaurantAdmissionTest do
  @moduledoc """
  Rebuild slice 3's host gate: restaurant orders admitted through the signed
  Log. The appender serializes admission, so concurrent copies of one checkout
  place exactly one order, and the order's history replays to its state (I₆).
  """
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias RestaurantCore.Admission

  @ch "chapter-genesis"
  @all ~w(checkout accept start_preparing mark_ready complete cancel dispatch fail)

  setup do
    gov = new_member("governance")
    pos = new_member("restaurant_device")
    kds = new_member("restaurant_device")
    ghost = new_member("restaurant_device")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    for {device, actor, actions} <- [{pos, "admin", @all}, {kds, "staff", @all -- ["checkout"]}] do
      {:ok, _} =
        Log.append(
          signed_event(gov, "RestaurantDeviceGrantedV1", %{
            "merchant_id" => "shop",
            "device_id" => "device-" <> device.signer.key_id,
            "key_id" => device.signer.key_id,
            "pubkey" => {:bytes, device.signer.pubkey},
            "actor" => actor,
            "actions" => actions
          })
        )
    end

    {:ok, pos: pos, kds: kds, ghost: ghost}
  end

  defp checkout(device, order_id),
    do:
      signed_event(device, "RestaurantOrderPlacedV1", %{
        "merchant_id" => "shop",
        "order_id" => order_id,
        "cart_id" => "cart",
        "principal_id" => "ada",
        "channel" => "web",
        "idempotency_key" => "k1",
        "fulfillment" => "pickup",
        "currency" => "USD",
        "lines" => [
          %{"name" => "Margherita", "unit_minor" => 1250, "quantity" => 2, "discount_minor" => 0}
        ],
        "subtotal_minor" => 2500,
        "total_minor" => 2500,
        "adjustments" => %{
          "discount_total" => 0,
          "tax_total" => 0,
          "delivery_fee" => 0,
          "tip" => 0
        }
      })

  defp step(device, action, version),
    do:
      signed_event(device, "RestaurantOrderStepV1", %{
        "merchant_id" => "shop",
        "order_id" => "o1",
        "command_id" => "c#{version}",
        "expected_version" => version,
        "action" => action
      })

  defp orders, do: get_in(Log.gate(), [:restaurant, :merchants, {@ch, "shop"}, :orders]) || %{}

  test "eight concurrent copies of one checkout place exactly one order", %{pos: pos} do
    results =
      1..8
      |> Enum.map(&checkout(pos, "o#{&1}"))
      |> Task.async_stream(&Log.append/1, max_concurrency: 8, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, [winner]}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert map_size(orders()) == 1
    assert %{state: :placed} = orders()[winner.payload["order_id"]]

    refusals = Enum.reject(results, &match?({:ok, _}, &1))
    assert length(refusals) == 7
    assert Enum.all?(refusals, &(inspect(&1) =~ "duplicate_checkout"))
  end

  test "an ungranted device, or a step its grant lacks, appends nothing", ctx do
    head = Log.head()
    assert {:error, refusal} = Log.append(checkout(ctx.ghost, "o1"))
    assert inspect(refusal) =~ "forbidden"
    assert {:error, _} = Log.append(checkout(ctx.kds, "o1"))
    assert Log.head() == head
    assert orders() == %{}
  end

  test "the kitchen walks an order to completion, and its history replays to the same state",
       ctx do
    {:ok, _} = Log.append(checkout(ctx.pos, "o1"))

    for {action, v} <- Enum.with_index(~w(accept start_preparing mark_ready complete)),
        do: assert({:ok, _} = Log.append(step(ctx.kds, action, v)))

    assert %{state: :completed, version: 4} = live = orders()["o1"]
    assert {:error, _} = Log.append(step(ctx.kds, "cancel", 4))

    {:ok, replayed} = Log.replay(Membership)
    assert Admission.state(replayed.restaurant, @ch, "shop", "o1") == live
  end
end
