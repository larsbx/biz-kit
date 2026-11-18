defmodule CoopSubstrate.RestaurantAdmissionTest do
  @moduledoc """
  Rebuild slice 3's host gate: restaurant orders admitted through the signed
  Log. The appender serializes admission, so concurrent copies of one checkout
  place exactly one order, and the order's history replays to its state (I₆).
  """
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Canonical, Constants, Log}
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.Admission

  @ch "chapter-genesis"
  @tenant "11111111-1111-1111-1111-111111111111"
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

    {:ok, gov: gov, pos: pos, kds: kds, ghost: ghost}
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

  defp dispatch_grant(gov, merchant, key_id, pubkey),
    do:
      signed_event(gov, "RestaurantDispatchGrantedV1", %{
        "merchant_id" => merchant,
        "tenant_id" => @tenant,
        "key_id" => key_id,
        "pubkey" => {:bytes, pubkey}
      })

  defp declare(gov, role, key_id, pubkey),
    do:
      signed_event(gov, "RoleKeyDeclared", %{
        "role" => role,
        "key_id" => key_id,
        "pubkey" => {:bytes, pubkey}
      })

  # Test-only: what an appender without the key fence committed. The record
  # goes straight to the EventStore, past validity, chained like any other.
  defp persist_unchecked!(event) do
    head = Log.head()
    {:ok, stream} = Envelope.stream_id(event)
    {:ok, prior} = Log.read_stream(stream)
    last = List.last(prior)
    {:ok, previous_hash} = Envelope.event_hash(last)

    assigned =
      Envelope.with_log_assignment(event, %{
        stream_id: stream,
        stream_seq: last.stream_seq + 1,
        global_seq: head.global_seq + 1,
        prev_global_hash: head.global_hash,
        prev_stream_hash: previous_hash
      })

    {:ok, uuid} = CoopSubstrate.ULID.to_uuid(event.event_id)

    data = %EventStore.EventData{
      event_id: uuid,
      event_type: event.type,
      data: Canonical.encode!(Envelope.full_record_term(assigned)),
      metadata: nil
    }

    :ok = CoopSubstrate.EventStore.append_to_stream("ledger", head.global_seq, [data])
  end

  test "a Dispatch key that reuses a device key appends nothing", ctx do
    head = Log.head()

    assert {:error, refusal} =
             Log.append(dispatch_grant(ctx.gov, "deli", "courier", ctx.pos.signer.pubkey))

    assert inspect(refusal) =~ "key_not_separate"
    assert Log.head() == head
  end

  test "a Dispatch key is never declared a role key afterwards, in any declarable role", ctx do
    courier = new_member("restaurant_dispatch")

    {:ok, _} =
      Log.append(dispatch_grant(ctx.gov, "shop", courier.signer.key_id, courier.signer.pubkey))

    head = Log.head()

    for role <- Constants.declarable_roles() do
      assert {:error, refusal} =
               Log.append(declare(ctx.gov, role, "k-" <> role, courier.signer.pubkey))

      assert inspect(refusal) =~ "key_not_separate", role
    end

    assert Log.head() == head
    # A fresh key is declared as before.
    assert {:ok, _} =
             Log.append(declare(ctx.gov, "steward", "k-fresh", new_member().signer.pubkey))
  end

  test "a ledger that already holds a collision boots, replays it, and refuses the next one",
       ctx do
    head = Log.head()
    # Admitted before the fence existed: a Dispatch grant on pos's device key.
    persist_unchecked!(dispatch_grant(ctx.gov, "shop", "courier", ctx.pos.signer.pubkey))
    restart_log()

    assert Log.head().global_seq == head.global_seq + 1
    grants = Log.gate().restaurant.grants
    assert %{actor: :dispatch} = grants[{@ch, "shop", "courier"}]
    assert %{actor: :admin} = grants[{@ch, "shop", ctx.pos.signer.key_id}]
    {:ok, replayed} = Log.replay(Membership)
    assert replayed.restaurant.grants == grants
    assert :ok = Log.verify_chains()

    head = Log.head()

    assert {:error, refusal} =
             Log.append(dispatch_grant(ctx.gov, "deli", "courier", ctx.pos.signer.pubkey))

    assert inspect(refusal) =~ "key_not_separate"
    assert Log.head() == head
  end
end
