defmodule CoopSubstrate.RestaurantDeliveryTest do
  @moduledoc """
  Slice 5's delivery handoff through the signed Log: every restaurant type is
  routed to `RestaurantCore.Admission`, Dispatch's steps are admitted only
  under its own role and granted key, races are serialized by the appender and
  decided by the (order, handoff) pair, and the ledger replays to the live gate.
  """
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.{Admission, Coupling}

  @ch "chapter-genesis"
  @all ~w(checkout accept start_preparing mark_ready complete cancel dispatch fail)

  setup do
    gov = new_member("governance")
    pos = new_member("restaurant_device")
    a = new_member("dispatch_transport")
    b = new_member("dispatch_transport")

    ok!(
      signed_event(gov, "RoleKeyDeclared", %{
        "role" => "governance",
        "key_id" => gov.signer.key_id,
        "pubkey" => {:bytes, gov.signer.pubkey}
      })
    )

    ok!(
      signed_event(gov, "RestaurantDeviceGrantedV1", %{
        "merchant_id" => "shop",
        "device_id" => "device-pos",
        "key_id" => pos.signer.key_id,
        "pubkey" => {:bytes, pos.signer.pubkey},
        "actor" => "admin",
        "actions" => @all
      })
    )

    for {key, dispatch} <- [{a, "d1"}, {b, "d2"}], do: ok!(transport_grant(gov, key, dispatch))
    {:ok, gov: gov, pos: pos, a: a, b: b}
  end

  defp ok!(event), do: {:ok, _} = Log.append(event)

  defp transport_grant(gov, key, dispatch),
    do:
      signed_event(gov, "RestaurantTransportGrantedV1", %{
        "merchant_id" => "shop",
        "dispatch_id" => dispatch,
        "key_id" => key.signer.key_id,
        "pubkey" => {:bytes, key.signer.pubkey}
      })

  defp place(pos, order_id),
    do:
      signed_event(pos, "RestaurantOrderPlacedV1", %{
        "merchant_id" => "shop",
        "order_id" => order_id,
        "cart_id" => "cart-" <> order_id,
        "principal_id" => "ada",
        "channel" => "web",
        "idempotency_key" => "k-" <> order_id,
        "fulfillment" => "delivery",
        "delivery" => %{"address" => "1 Main St"},
        "currency" => "USD",
        "lines" => [
          %{"name" => "Margherita", "unit_minor" => 1250, "quantity" => 2, "discount_minor" => 0}
        ],
        "subtotal_minor" => 2500,
        "total_minor" => 2899,
        "adjustments" => %{
          "discount_total" => 0,
          "tax_total" => 0,
          "delivery_fee" => 399,
          "tip" => 0
        }
      })

  defp step(pos, order_id, action, version),
    do:
      signed_event(pos, "RestaurantOrderStepV1", %{
        "merchant_id" => "shop",
        "order_id" => order_id,
        "command_id" => "c#{version}",
        "expected_version" => version,
        "action" => action,
        "reason" => "because"
      })

  defp request(pos, order_id, request_id),
    do:
      signed_event(pos, "RestaurantTransportRequestedV1", %{
        "merchant_id" => "shop",
        "order_id" => order_id,
        "request_id" => request_id,
        "expected_version" => 3
      })

  defp withdraw(pos, order_id, request_id, version),
    do:
      signed_event(pos, "RestaurantTransportCancelRequestedV1", %{
        "merchant_id" => "shop",
        "order_id" => order_id,
        "request_id" => request_id,
        "command_id" => "w#{version}",
        "expected_version" => version,
        "reason" => "customer called"
      })

  defp dispatch(key, order_id, request_id, op, version, fields \\ %{}),
    do:
      signed_event(
        key,
        "RestaurantTransportStepV1",
        Map.merge(
          %{
            "merchant_id" => "shop",
            "order_id" => order_id,
            "request_id" => request_id,
            "step_id" => "#{op}-#{version}-#{System.unique_integer([:positive])}",
            "expected_version" => version,
            "op" => op
          },
          fields
        )
      )

  defp digest(seed), do: {:bytes, :crypto.hash(:sha256, seed)}

  # A delivery order at ready (version 3) with a pending transport request.
  defp requested(ctx, order_id) do
    ok!(place(ctx.pos, order_id))

    for {action, v} <- Enum.with_index(~w(accept start_preparing mark_ready)),
        do: ok!(step(ctx.pos, order_id, action, v))

    ok!(request(ctx.pos, order_id, "r-" <> order_id))
  end

  defp gate, do: Log.gate().restaurant

  defp pair(order_id) do
    order = Admission.state(gate(), @ch, "shop", order_id)
    handoff = Admission.handoff(gate(), @ch, "shop", order_id)
    {order.state, Coupling.view(handoff && handoff.fc)}
  end

  test "every restaurant type is judged by RestaurantCore.Admission, never a catch-all", ctx do
    ghost = new_member("restaurant_device")
    stranger = new_member("dispatch_transport")
    head = Log.head()

    for event <- [
          transport_grant(ctx.gov, stranger, ""),
          signed_event(ctx.gov, "RestaurantDeviceGrantedV1", %{
            "merchant_id" => "shop",
            "device_id" => "device-ghost",
            "key_id" => ghost.signer.key_id,
            "pubkey" => {:bytes, ghost.signer.pubkey},
            "actor" => "root",
            "actions" => @all
          }),
          place(ghost, "o1"),
          step(ghost, "o1", "accept", 0),
          request(ghost, "o1", "r1"),
          withdraw(ghost, "o1", "r1", 0),
          dispatch(stranger, "o1", "r1", "accept", 0, %{"transport_ref" => "trip"})
        ] do
      assert {:error, refusal} = Log.append(event)

      assert inspect(refusal) =~ ~r/forbidden|invalid_transport_grant|invalid_restaurant_grant/,
             inspect(refusal)
    end

    assert Log.head() == head
  end

  test "only Dispatch's role and granted key sign a transport step", ctx do
    requested(ctx, "o1")

    assert {:error, {:roles_mismatch, _}} =
             Envelope.new(%{
               event_id: CoopSubstrate.ULID.generate(),
               chapter_id: @ch,
               type: "RestaurantTransportStepV1",
               payload: %{
                 "merchant_id" => "shop",
                 "order_id" => "o1",
                 "request_id" => "r-o1",
                 "step_id" => "s1",
                 "expected_version" => 0,
                 "op" => "accept",
                 "transport_ref" => "trip"
               },
               signers: [ctx.pos.signer],
               auth_ref: nil,
               timestamp_ms: System.system_time(:millisecond)
             })

    board_as_dispatch = %{ctx.pos | signer: %{ctx.pos.signer | role: "dispatch_transport"}}
    head = Log.head()

    assert {:error, refusal} =
             Log.append(
               dispatch(board_as_dispatch, "o1", "r-o1", "accept", 0, %{"transport_ref" => "t"})
             )

    assert inspect(refusal) =~ "forbidden"

    assert {:error, refusal} = Log.append(transport_grant(ctx.gov, ctx.pos, "d9"))
    assert inspect(refusal) =~ "key_not_separate"
    assert Log.head() == head
  end

  test "a transport key is never declared a role key afterwards, as no role key is granted for transport",
       ctx do
    head = Log.head()

    for role <- ~w(governance steward checkpoint) do
      declare =
        signed_event(ctx.gov, "RoleKeyDeclared", %{
          "role" => role,
          "key_id" => "k-reuse-" <> role,
          "pubkey" => {:bytes, ctx.a.signer.pubkey}
        })

      assert {:error, refusal} = Log.append(declare)
      assert inspect(refusal) =~ "key_not_separate"
    end

    assert Log.head() == head
  end

  test "a delivery is requested, accepted, picked up and delivered with proof; another fails in transit; the ledger replays to the gate",
       ctx do
    requested(ctx, "o1")
    ok!(dispatch(ctx.a, "o1", "r-o1", "accept", 0, %{"transport_ref" => "trip-1"}))
    assert pair("o1") == {:ready, :accepted}
    ok!(dispatch(ctx.a, "o1", "r-o1", "in_transit", 1))
    assert pair("o1") == {:dispatched, :in_transit}
    ok!(dispatch(ctx.a, "o1", "r-o1", "delivered", 2, %{"proof" => digest("bundle-1")}))
    assert pair("o1") == {:completed, :delivered}

    requested(ctx, "o2")
    ok!(dispatch(ctx.a, "o2", "r-o2", "accept", 0, %{"transport_ref" => "trip-2"}))
    ok!(dispatch(ctx.a, "o2", "r-o2", "in_transit", 1))

    assert {:error, refusal} =
             Log.append(
               dispatch(ctx.a, "o2", "r-o2", "failed", 2, %{
                 "reason" => "nobody home",
                 "proof" => digest("bundle-1")
               })
             )

    assert inspect(refusal) =~ "proof_reused"

    ok!(
      dispatch(ctx.a, "o2", "r-o2", "failed", 2, %{
        "reason" => "nobody home",
        "proof" => digest("bundle-2")
      })
    )

    assert pair("o2") == {:failed, :failed_in_transit}

    requested(ctx, "o3")
    ok!(withdraw(ctx.pos, "o3", "r-o3", 0))
    ok!(step(ctx.pos, "o3", "cancel", 3))
    assert pair("o3") == {:cancelled, :withdrawn}

    {:ok, replayed} = Log.replay(Membership)
    assert replayed.restaurant == gate()
  end

  test "eight concurrent accepts at one handoff version admit exactly one", ctx do
    requested(ctx, "o1")

    results =
      1..8
      |> Enum.map(&dispatch(ctx.a, "o1", "r-o1", "accept", 0, %{"transport_ref" => "trip-#{&1}"}))
      |> Task.async_stream(&Log.append/1, max_concurrency: 8, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [_] = Enum.filter(results, &match?({:ok, _}, &1))
    refusals = Enum.reject(results, &match?({:ok, _}, &1))

    assert length(refusals) == 7 and
             Enum.all?(refusals, &(inspect(&1) =~ "stale_fulfillment_version"))

    assert pair("o1") == {:ready, :accepted}
  end

  test "a withdrawal racing Dispatch is decided by whichever the appender admits first", ctx do
    races = [
      {"o1", fn -> [] end, dispatch(ctx.a, "o1", "r-o1", "accept", 0, %{"transport_ref" => "t"}),
       withdraw(ctx.pos, "o1", "r-o1", 0), [{:ready, :accepted}, {:ready, :withdrawn}]},
      {"o2", fn -> ok!(dispatch(ctx.a, "o2", "r-o2", "accept", 0, %{"transport_ref" => "t"})) end,
       dispatch(ctx.a, "o2", "r-o2", "in_transit", 1), withdraw(ctx.pos, "o2", "r-o2", 1),
       [{:dispatched, :in_transit}, {:ready, :cancel_pending}]}
    ]

    for {order_id, before, dispatch_event, withdraw_event, outcomes} <- races do
      requested(ctx, order_id)
      before.()

      results =
        [dispatch_event, withdraw_event]
        |> Task.async_stream(&Log.append/1, max_concurrency: 2, ordered: true)
        |> Enum.map(fn {:ok, result} -> result end)

      assert [_] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, loser}] = Enum.reject(results, &match?({:ok, _}, &1))
      assert inspect(loser) =~ "stale_fulfillment_version"
      assert pair(order_id) in outcomes
    end
  end
end
