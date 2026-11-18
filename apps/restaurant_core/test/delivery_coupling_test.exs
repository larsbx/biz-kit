defmodule RestaurantCore.DeliveryCouplingTest do
  @moduledoc """
  I8 over every pair for the fixed-route delivery pilot: a delivery order's
  transport states come only from Dispatch's signed steps, its kitchen states
  only from the restaurant's.

  The relation is stated as data: the (order state, handoff phase) pairs the
  pilot can reach and the steps between them, each with its owner. A
  breadth-first search over the real `Admission.check/2` and `fold/2`, offering
  every kitchen action and every Dispatch op at each reached pair (and each
  signed by the other side's key too), must reach exactly these pairs and
  admit exactly these steps, for automated (code-bound) and arranged orders.
  A change to delivery semantics changes these tables on purpose.
  """
  use ExUnit.Case, async: true

  alias FulfillmentCore.OrderCoupling
  alias RestaurantCore.{Admission, Delivery}

  @ch "chapter"
  @merchant "shop"
  @tenant "11111111-1111-1111-1111-111111111111"
  @load "22222222-2222-2222-2222-222222222222"
  @assignment "55555555-5555-5555-5555-555555555555"
  @gov %{role: "governance", key_id: "gov", pubkey: :binary.copy(<<1>>, 32)}
  @all ~w(checkout accept start_preparing mark_ready complete cancel dispatch fail)
  @kitchen ~w(accept start_preparing mark_ready complete cancel dispatch fail)
  @dispatch_ops ~w(accept picked_up delivered failed reject cancel_confirmed)

  @pairs [
    placed: nil,
    accepted: nil,
    preparing: nil,
    ready: nil,
    cancelled: nil,
    ready: :accepted,
    dispatched: :in_transit,
    completed: :delivered
  ]

  # {from, owner, op, to}
  @edges [
    {{:placed, nil}, :restaurant, "accept", {:accepted, nil}},
    {{:accepted, nil}, :restaurant, "start_preparing", {:preparing, nil}},
    {{:preparing, nil}, :restaurant, "mark_ready", {:ready, nil}},
    {{:placed, nil}, :restaurant, "cancel", {:cancelled, nil}},
    {{:accepted, nil}, :restaurant, "cancel", {:cancelled, nil}},
    {{:preparing, nil}, :restaurant, "cancel", {:cancelled, nil}},
    {{:ready, nil}, :restaurant, "cancel", {:cancelled, nil}},
    {{:ready, nil}, :dispatch, "accept", {:ready, :accepted}},
    {{:ready, :accepted}, :dispatch, "picked_up", {:dispatched, :in_transit}},
    {{:dispatched, :in_transit}, :dispatch, "delivered", {:completed, :delivered}}
  ]

  defp device(id),
    do: %{role: "restaurant_device", key_id: id, pubkey: :crypto.hash(:sha256, id)}

  defp dispatch(id),
    do: %{role: "restaurant_dispatch", key_id: id, pubkey: :crypto.hash(:sha256, "d:" <> id)}

  defp env(type, signer, payload),
    do: %{type: type, chapter_id: @ch, signers: [signer], payload: payload}

  defp code(order_id, phase), do: "code-#{order_id}-#{phase}"
  defp digest(code), do: Base.encode16(:crypto.hash(:sha256, code), case: :lower)

  defp place(order_id, automated?) do
    delivery =
      if automated?,
        do: %{
          "profile" => "automatic-v1",
          "site" => "North desk",
          "request_id" => order_id,
          "pickup_digest" => digest(code(order_id, "picked_up")),
          "dropoff_digest" => digest(code(order_id, "delivered"))
        },
        else: %{"request_id" => order_id}

    env("RestaurantOrderPlacedV1", device("pos"), %{
      "merchant_id" => @merchant,
      "order_id" => order_id,
      "cart_id" => "cart-" <> order_id,
      "principal_id" => "ada",
      "channel" => "web",
      "idempotency_key" => "k-" <> order_id,
      "fulfillment" => "delivery",
      "currency" => "USD",
      "lines" => [
        %{"name" => "Margherita", "unit_minor" => 1250, "quantity" => 1, "discount_minor" => 0}
      ],
      "subtotal_minor" => 1250,
      "total_minor" => 1250,
      "adjustments" => %{
        "discount_total" => 0,
        "tax_total" => 0,
        "delivery_fee" => 0,
        "tip" => 0
      },
      "delivery" => delivery
    })
  end

  defp kitchen(order_id, action, version, signer \\ device("pos")),
    do:
      env("RestaurantOrderStepV1", signer, %{
        "merchant_id" => @merchant,
        "order_id" => order_id,
        "command_id" => "k-#{action}-#{version}-#{signer.key_id}",
        "expected_version" => version,
        "action" => action,
        "reason" => "guest asked"
      })

  # A Dispatch step with valid evidence for its op at the handoff version.
  defp dispatch_step(order_id, op, version, automated?, signer \\ dispatch("courier")) do
    proof =
      case op do
        "picked_up" -> "33333333-3333-3333-3333-333333333333"
        "delivered" -> "44444444-4444-4444-4444-444444444444"
        "failed" -> "77777777-7777-7777-7777-777777777777"
        _ -> nil
      end

    %{
      "merchant_id" => @merchant,
      "order_id" => order_id,
      "tenant_id" => @tenant,
      "load_id" => @load,
      "assignment_id" => @assignment,
      "command_id" => "d-#{op}-#{version}-#{signer.key_id}",
      "expected_version" => version,
      "op" => op
    }
    |> then(&if proof, do: Map.put(&1, "proof_id", proof), else: &1)
    |> then(&if automated?, do: Map.put(&1, "automated", true), else: &1)
    |> then(
      &if automated? and op in ~w(picked_up delivered),
        do: Map.put(&1, "proof_digest", digest(code(order_id, op))),
        else: &1
    )
    |> then(&env("RestaurantDeliveryStepV1", signer, &1))
  end

  defp admit(g, events) do
    Enum.reduce(events, g, fn e, g ->
      assert Admission.check(e, g) == :ok, inspect({e.type, e.payload, Admission.check(e, g)})
      %{g | restaurant: Admission.fold(e, g)}
    end)
  end

  defp placed(order_id, automated?) do
    admit(
      %{
        role_keys: %{{@ch, "governance"} => %{"gov" => @gov.pubkey}},
        restaurant: Admission.init()
      },
      [
        env("RestaurantDeviceGrantedV1", @gov, %{
          "merchant_id" => @merchant,
          "device_id" => "device-pos",
          "key_id" => "pos",
          "pubkey" => {:bytes, device("pos").pubkey},
          "actor" => "admin",
          "actions" => @all
        }),
        env("RestaurantDispatchGrantedV1", @gov, %{
          "merchant_id" => @merchant,
          "tenant_id" => @tenant,
          "key_id" => "courier",
          "pubkey" => {:bytes, dispatch("courier").pubkey}
        }),
        place(order_id, automated?)
      ]
    )
  end

  defp order(g, order_id), do: Admission.state(g.restaurant, @ch, @merchant, order_id)
  defp handoff(g, order_id), do: Delivery.handoff(g.restaurant.delivery, @ch, @merchant, order_id)

  defp pair(g, order_id) do
    h = handoff(g, order_id)
    {order(g, order_id).state, h && h.phase}
  end

  # Every kitchen action and every Dispatch op at the current versions, each
  # signed by its own side and, forged, by the other side's key.
  defp offers(g, order_id, automated?) do
    ov = order(g, order_id).version
    hv = if h = handoff(g, order_id), do: h.version, else: 0

    for action <- @kitchen,
        signer <- [{:restaurant, device("pos")}, {:dispatch, dispatch("courier")}] do
      {elem(signer, 0), action, kitchen(order_id, action, ov, elem(signer, 1))}
    end ++
      for op <- @dispatch_ops,
          signer <- [{:dispatch, dispatch("courier")}, {:restaurant, device("pos")}] do
        {elem(signer, 0), op, dispatch_step(order_id, op, hv, automated?, elem(signer, 1))}
      end
  end

  defp explore(order_id, automated?) do
    start = placed(order_id, automated?)

    Stream.iterate({%{pair(start, order_id) => start}, [start], MapSet.new(), %{}}, fn
      {reps, frontier, steps, refusals} ->
        results =
          for g <- frontier, {signer, op, e} <- offers(g, order_id, automated?) do
            case Admission.check(e, g) do
              :ok ->
                n = %{g | restaurant: Admission.fold(e, g)}
                {:admitted, n, {pair(g, order_id), signer, e.type, op, pair(n, order_id)}}

              {:error, reason} ->
                assert_raise MatchError, fn -> Admission.fold(e, g) end
                {:refused, pair(g, order_id), reason}
            end
          end

        admitted = for {:admitted, n, step} <- results, do: {n, step}

        fresh =
          admitted
          |> Enum.map(&elem(&1, 0))
          |> Enum.reject(&Map.has_key?(reps, pair(&1, order_id)))
          |> Enum.uniq_by(&pair(&1, order_id))

        refusals =
          Enum.reduce(for({:refused, _, reason} <- results, do: reason), refusals, fn r, acc ->
            Map.update(acc, r, 1, &(&1 + 1))
          end)

        {Map.merge(reps, Map.new(fresh, &{pair(&1, order_id), &1})), fresh,
         MapSet.union(steps, MapSet.new(admitted, &elem(&1, 1))), refusals}
    end)
    |> Enum.find(fn {_, frontier, _, _} -> frontier == [] end)
  end

  test "the relation: owners and the order's lifecycle agree with the pinned coupling policy" do
    assert length(Enum.uniq(@pairs)) == 8 and length(Enum.uniq(@edges)) == 10

    for {{s, h} = from, owner, _op, {t, w} = to} <- @edges do
      assert from in @pairs and to in @pairs

      cond do
        t != s ->
          assert OrderCoupling.order_edge_owner(s, t) ==
                   if(owner == :dispatch, do: :delivery, else: :order)

          assert w == h or owner == :dispatch

        true ->
          assert owner == :dispatch and w != h
      end
    end
  end

  for automated? <- [true, false] do
    @tag automated: automated?
    test "every pair, every step (#{if automated?, do: "automated", else: "arranged"} order): exactly the relation is reachable, from exactly its owner",
         %{automated: automated?} do
      {reps, _, steps, refusals} = explore("order", automated?)

      assert Enum.sort(Map.keys(reps)) == Enum.sort(@pairs)

      assert MapSet.new(steps, fn {from, owner, _type, op, to} -> {from, owner, op, to} end) ==
               MapSet.new(@edges)

      for {_, owner, type, _, _} <- steps,
          do:
            assert(
              type ==
                if(owner == :restaurant,
                  do: "RestaurantOrderStepV1",
                  else: "RestaurantDeliveryStepV1"
                )
            )

      # Each reached pair offers 7 kitchen actions and 6 Dispatch ops, each
      # signed by both sides: 26 events, of which only the relation's steps pass.
      assert Enum.sum(Map.values(refusals)) == 8 * 26 - 10
      assert refusals[:forbidden] >= 8 * 13
    end
  end

  test "after a kitchen cancel, no Dispatch step is admitted and nothing changes; after acceptance, the cancel is refused" do
    for automated? <- [true, false] do
      g = placed("order", automated?)

      g =
        admit(g, [
          kitchen("order", "accept", 0),
          kitchen("order", "start_preparing", 1),
          kitchen("order", "mark_ready", 2)
        ])

      cancelled = admit(g, [kitchen("order", "cancel", 3)])

      for op <- ~w(accept picked_up delivered) do
        assert Admission.check(dispatch_step("order", op, 0, automated?), cancelled) ==
                 {:error, :delivery_order_not_ready}
      end

      assert pair(cancelled, "order") == {:cancelled, nil}

      accepted = admit(g, [dispatch_step("order", "accept", 0, automated?)])

      assert Admission.check(kitchen("order", "cancel", 3), accepted) ==
               {:error, :dispatch_custody_reconciliation_required}

      moving = admit(accepted, [dispatch_step("order", "picked_up", 1, automated?)])

      assert Admission.check(kitchen("order", "cancel", 4), moving) ==
               {:error, :dispatch_custody_reconciliation_required}
    end
  end
end
