defmodule RestaurantCore.DeliveryAdmissionTest do
  @moduledoc """
  Admission of the delivery handoff: a transport key class only governance
  grants, restaurant requests and withdrawals, Dispatch's signed steps, and the
  I8 relation enforced over every pair and every step of the real `check/2`
  and `fold/2`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestaurantCore.{Admission, Coupling, Kitchen}

  @ch "chapter"
  @gov %{role: "governance", key_id: "gov", pubkey: :binary.copy(<<1>>, 32)}
  @all ~w(checkout accept start_preparing mark_ready complete cancel dispatch fail)
  @owned ~w(dispatched completed failed)a

  defp device(id),
    do: %{role: "restaurant_device", key_id: id, pubkey: :crypto.hash(:sha256, id)}

  defp transport(id),
    do: %{role: "dispatch_transport", key_id: id, pubkey: :crypto.hash(:sha256, "t:" <> id)}

  defp env(type, signer, payload),
    do: %{type: type, chapter_id: @ch, signers: [signer], payload: payload}

  defp grant(id, actor, actions, merchant \\ "shop", pubkey \\ nil),
    do:
      env("RestaurantDeviceGrantedV1", @gov, %{
        "merchant_id" => merchant,
        "device_id" => "device-" <> id,
        "key_id" => id,
        "pubkey" => {:bytes, pubkey || device(id).pubkey},
        "actor" => actor,
        "actions" => actions
      })

  defp tgrant(id, dispatch, merchant \\ "shop", pubkey \\ nil),
    do:
      env("RestaurantTransportGrantedV1", @gov, %{
        "merchant_id" => merchant,
        "dispatch_id" => dispatch,
        "key_id" => id,
        "pubkey" => {:bytes, pubkey || transport(id).pubkey}
      })

  defp place(signer, extra \\ %{}),
    do:
      env(
        "RestaurantOrderPlacedV1",
        signer,
        Map.merge(
          %{
            "merchant_id" => "shop",
            "order_id" => "o1",
            "cart_id" => "cart",
            "principal_id" => "ada",
            "channel" => "web",
            "idempotency_key" => "k1",
            "fulfillment" => "delivery",
            "delivery" => %{"address" => "1 Main St"},
            "currency" => "USD",
            "lines" => [
              %{
                "name" => "Margherita",
                "unit_minor" => 1250,
                "quantity" => 2,
                "discount_minor" => 0
              }
            ],
            "subtotal_minor" => 2500,
            "total_minor" => 2899,
            "adjustments" => %{
              "discount_total" => 0,
              "tax_total" => 0,
              "delivery_fee" => 399,
              "tip" => 0
            }
          },
          extra
        )
      )

  defp step(signer, action, version, extra \\ %{}),
    do:
      env(
        "RestaurantOrderStepV1",
        signer,
        Map.merge(
          %{
            "merchant_id" => "shop",
            "order_id" => "o1",
            "command_id" => "c#{version}",
            "expected_version" => version,
            "action" => action,
            "reason" => "because"
          },
          extra
        )
      )

  defp request(signer, version, extra \\ %{}),
    do:
      env(
        "RestaurantTransportRequestedV1",
        signer,
        Map.merge(
          %{
            "merchant_id" => "shop",
            "order_id" => "o1",
            "request_id" => "r1",
            "expected_version" => version
          },
          extra
        )
      )

  defp withdraw(signer, version, extra \\ %{}),
    do:
      env(
        "RestaurantTransportCancelRequestedV1",
        signer,
        Map.merge(
          %{
            "merchant_id" => "shop",
            "order_id" => "o1",
            "request_id" => "r1",
            "command_id" => "w#{version}",
            "expected_version" => version,
            "reason" => "customer called"
          },
          extra
        )
      )

  defp proof(seed), do: {:bytes, :crypto.hash(:sha256, seed)}

  defp fields("accept", _), do: %{"transport_ref" => "trip-1"}
  defp fields("reject", _), do: %{"reason" => "no drivers"}
  defp fields("delivered", id), do: %{"proof" => proof("delivered:" <> id)}
  defp fields("failed", id), do: %{"reason" => "nobody home", "proof" => proof("failed:" <> id)}
  defp fields(_, _), do: %{}

  defp dispatch(signer, op, version, extra \\ %{}) do
    id = Map.get(extra, "step_id", "s#{version}")

    env(
      "RestaurantTransportStepV1",
      signer,
      %{
        "merchant_id" => "shop",
        "order_id" => "o1",
        "request_id" => "r1",
        "step_id" => id,
        "expected_version" => version,
        "op" => op
      }
      |> Map.merge(fields(op, id))
      |> Map.merge(extra)
    )
  end

  defp empty,
    do: %{
      role_keys: %{{@ch, "governance"} => %{"gov" => @gov.pubkey}},
      restaurant: Admission.init()
    }

  defp admit(g, events) do
    Enum.reduce(events, g, fn e, g ->
      assert Admission.check(e, g) == :ok, inspect({e.type, e.payload, Admission.check(e, g)})
      %{g | restaurant: Admission.fold(e, g)}
    end)
  end

  defp gate(events), do: admit(empty(), events)

  defp staffed,
    do:
      gate([
        grant("pos", "admin", @all),
        grant("kds", "staff", @all),
        grant("bot", "system", @all),
        tgrant("A", "d1"),
        tgrant("B", "d2")
      ])

  # A delivery order at ready, version 3.
  defp ready(g \\ staffed(), extra \\ %{}),
    do:
      admit(g, [
        place(device("pos"), extra),
        step(device("pos"), "accept", 0),
        step(device("pos"), "start_preparing", 1),
        step(device("pos"), "mark_ready", 2)
      ])

  defp order(g, id \\ "o1"), do: Admission.state(g.restaurant, @ch, "shop", id)
  defp handoff(g, id \\ "o1"), do: Admission.handoff(g.restaurant, @ch, "shop", id)

  defp pair(g, id \\ "o1"),
    do: {order(g, id).state, Coupling.view(handoff(g, id) && handoff(g, id).fc)}

  test "Dispatch signs exactly one type, under its own role" do
    assert for({t, %{required_roles: ["dispatch_transport"]}} <- Admission.event_types(), do: t) ==
             ["RestaurantTransportStepV1"]
  end

  describe "transport grants" do
    test "only a declared governance key grants, once per key, with a well-formed body" do
      g = gate([])
      rogue = %{@gov | pubkey: :binary.copy(<<2>>, 32)}

      assert Admission.check(%{tgrant("A", "d1") | signers: [rogue]}, g) ==
               {:error, :restaurant_governance_not_declared}

      for {k, v} <- [
            {"dispatch_id", ""},
            {"dispatch_id", 7},
            {"key_id", String.duplicate("k", 129)},
            {"merchant_id", ""},
            {"pubkey", {:bytes, "short"}}
          ] do
        bad = update_in(tgrant("A", "d1").payload, &Map.put(&1, k, v))
        assert Admission.check(bad, g) == {:error, :invalid_transport_grant}, inspect(k)
      end

      g = admit(g, [tgrant("A", "d1")])
      assert Admission.check(tgrant("A", "d1"), g) == {:error, :transport_key_already_granted}
      assert Admission.check(tgrant("A", "d1", "other-shop"), g) == :ok
      assert Admission.transport?(g.restaurant, @ch, "shop")
      refute Admission.transport?(g.restaurant, @ch, "other-shop")
      refute Admission.transport?(g.restaurant, "other-chapter", "shop")
    end

    # The converse for role keys (a RoleKeyDeclared reusing a transport key) is
    # the substrate's rule: apps/coop_substrate/test/restaurant_delivery_test.exs.
    test "a transport key shares nothing with any device or declared role key, in any chapter, in both directions" do
      g = gate([grant("pos", "admin", @all), tgrant("A", "d1")])
      g = put_in(g.role_keys[{@ch, "steward"}], %{"st" => :binary.copy(<<9>>, 32)})
      g = put_in(g.role_keys[{"other", "governance"}], %{"gov" => @gov.pubkey})
      g = put_in(g.role_keys[{"other", "checkpoint"}], %{"cp" => :binary.copy(<<8>>, 32)})
      elsewhere = admit(g, [%{grant("x", "admin", @all) | chapter_id: "other"}])

      for {bad, g} <- [
            {tgrant("T1", "d1", "shop", device("pos").pubkey), g},
            {tgrant("T2", "d1", "shop", device("x").pubkey), elsewhere},
            {tgrant("T3", "d1", "shop", @gov.pubkey), g},
            {tgrant("T4", "d1", "shop", :binary.copy(<<9>>, 32)), g},
            {tgrant("T6", "d1", "shop", :binary.copy(<<8>>, 32)), g},
            {tgrant("T5", "d2", "shop", transport("A").pubkey), g},
            {tgrant("pos", "d1"), g},
            {grant("y", "staff", ["accept"], "shop", transport("A").pubkey), g},
            {grant("A", "staff", ["accept"]), g}
          ],
          do: assert(Admission.check(bad, g) == {:error, :key_not_separate}, inspect(bad.payload))

      assert Admission.check(tgrant("A2", "d1", "shop", transport("A").pubkey), g) == :ok
      assert Admission.check(tgrant("A", "d1", "other-shop"), g) == :ok
      assert Admission.transport_pubkey?(g.restaurant, {:bytes, transport("A").pubkey})
      refute Admission.transport_pubkey?(g.restaurant, device("pos").pubkey)
    end
  end

  describe "transport requests" do
    test "precedence: authority, order, id, delivery, idempotency, version, transport authority, address, state" do
      g = ready()
      assert Admission.check(request(device("bot"), 3), g) == {:error, :forbidden}
      assert Admission.check(request(device("ghost"), 3), g) == {:error, :forbidden}

      assert Admission.check(request(device("pos"), 3, %{"order_id" => "nope"}), g) ==
               {:error, :forbidden}

      for rid <- ["", String.duplicate("r", 129)],
          do:
            assert(
              Admission.check(request(device("pos"), 3, %{"request_id" => rid}), g) ==
                {:error, :invalid_transport_request}
            )

      pickup =
        admit(g, [
          place(device("pos"), %{
            "order_id" => "o2",
            "cart_id" => "c2",
            "idempotency_key" => "k2",
            "fulfillment" => "pickup"
          })
        ])

      assert Admission.check(request(device("pos"), 0, %{"order_id" => "o2"}), pickup) ==
               {:error, :not_a_delivery_order}

      assert Admission.check(request(device("pos"), 2), g) == {:error, :stale_order_version}

      requested = admit(g, [request(device("kds"), 3)])
      assert pair(requested) == {:ready, :requested}
      assert order(requested) == order(g)

      assert Admission.check(request(device("kds"), 3), requested) ==
               {:error, {:duplicate_request, "r1"}}

      assert Admission.check(request(device("pos"), 3), requested) ==
               {:error, :request_id_conflict}

      assert Admission.check(request(device("kds"), 3, %{"request_id" => "r2"}), requested) ==
               {:error, :transport_already_requested}

      bare = ready(gate([grant("pos", "admin", @all), tgrant("A", "d1", "other-shop")]))
      assert Admission.check(request(device("pos"), 3), bare) == {:error, :no_transport_authority}

      for address <- [nil, "", "   ", String.duplicate("a", 201)] do
        delivery = if address, do: %{"address" => address}, else: %{}
        g = ready(staffed(), %{"delivery" => delivery})

        assert Admission.check(request(device("pos"), 3), g) ==
                 {:error, :delivery_address_required}
      end

      early = admit(staffed(), [place(device("pos")), step(device("pos"), "accept", 0)])
      assert Admission.check(request(device("pos"), 1), early) == {:error, :order_not_ready}
    end
  end

  test "requesting a driver takes mark_ready and withdrawing takes cancel, under the kitchen's roles" do
    g =
      ready()
      |> admit([
        grant("ready-only", "staff", ["mark_ready"]),
        grant("cancel-only", "staff", ["cancel"])
      ])

    assert Admission.check(request(device("cancel-only"), 3), g) == {:error, :forbidden}
    g = admit(g, [request(device("ready-only"), 3)])
    assert Admission.check(withdraw(device("ready-only"), 0), g) == {:error, :forbidden}
    assert Admission.check(withdraw(device("cancel-only"), 0), g) == :ok
  end

  describe "withdrawals" do
    test "precedence: authority, order, handoff, reason, then FulfillmentCore and the relation" do
      g = ready() |> admit([grant("kds2", "staff", ["mark_ready"])])
      assert Admission.check(withdraw(device("pos"), 0), g) == {:error, :unknown_handoff}

      g = admit(g, [request(device("pos"), 3)])
      assert Admission.check(withdraw(device("bot"), 0), g) == {:error, :forbidden}
      assert Admission.check(withdraw(device("kds2"), 0), g) == {:error, :forbidden}

      assert Admission.check(withdraw(device("pos"), 0, %{"order_id" => "nope"}), g) ==
               {:error, :forbidden}

      assert Admission.check(withdraw(device("pos"), 0, %{"request_id" => "r9"}), g) ==
               {:error, :unknown_handoff}

      assert Admission.check(withdraw(device("pos"), 0, %{"reason" => ""}), g) ==
               {:error, :reason_required}

      assert Admission.check(withdraw(device("pos"), 1), g) ==
               {:error, :stale_fulfillment_version}

      w = admit(g, [withdraw(device("pos"), 0)])
      assert pair(w) == {:ready, :withdrawn} and order(w) == order(g)

      assert Admission.check(withdraw(device("pos"), 0), w) ==
               {:error, {:duplicate_command, "w0"}}

      assert Admission.check(withdraw(device("pos"), 0, %{"reason" => "other"}), w) ==
               {:error, :idempotency_conflict}

      assert Admission.check(withdraw(device("pos"), 1), w) ==
               {:error, :invalid_fulfillment_transition}

      moving =
        admit(g, [
          dispatch(transport("A"), "accept", 0),
          dispatch(transport("A"), "in_transit", 1)
        ])

      assert Admission.check(withdraw(device("pos"), 2), moving) == {:error, :transport_started}

      rejected = admit(g, [dispatch(transport("A"), "reject", 0)])

      assert Admission.check(withdraw(device("pos"), 1), rejected) ==
               {:error, :terminal_fulfillment}
    end
  end

  describe "Dispatch steps" do
    test "only a granted transport key of the merchant signs, and after acceptance only the accepting Dispatch" do
      g = ready() |> admit([request(device("pos"), 3), tgrant("C", "d3", "other-shop")])
      pos_as_dispatch = %{device("pos") | role: "dispatch_transport"}

      for signer <- [
            pos_as_dispatch,
            %{transport("A") | pubkey: transport("B").pubkey},
            transport("C"),
            transport("Z")
          ],
          do: assert(Admission.check(dispatch(signer, "accept", 0), g) == {:error, :forbidden})

      a = admit(g, [dispatch(transport("A"), "accept", 0)])
      assert handoff(a).accepted_by == "d1"
      assert Admission.check(dispatch(transport("B"), "in_transit", 1), a) == {:error, :forbidden}
      assert Admission.check(dispatch(transport("A"), "in_transit", 1), a) == :ok
    end

    test "fields are exact per op, and both outcomes carry proof" do
      spec = Admission.event_types()["RestaurantTransportStepV1"].payload
      assert spec.optional == %{"transport_ref" => :string, "reason" => :string, "proof" => :hash}
      g = ready() |> admit([request(device("pos"), 3)])

      for bad <- [
            dispatch(transport("A"), "teleport", 0),
            dispatch(transport("A"), "accept", 0, %{"proof" => proof("x")}),
            update_in(
              dispatch(transport("A"), "accept", 0).payload,
              &Map.delete(&1, "transport_ref")
            ),
            dispatch(transport("A"), "in_transit", 0, %{"reason" => "x"}),
            dispatch(transport("A"), "delivered", 0, %{"reason" => "x"})
          ],
          do:
            assert(
              Admission.check(bad, g) == {:error, :invalid_transport_step},
              inspect(bad.payload)
            )

      for op <- ["delivered", "failed"],
          do:
            assert(
              Admission.check(
                update_in(dispatch(transport("A"), op, 0).payload, &Map.delete(&1, "proof")),
                g
              ) ==
                {:error, :proof_required}
            )
    end

    test "handoff identity, FulfillmentCore's refusals, the strict cells and proof reuse" do
      none = ready()

      assert Admission.check(dispatch(transport("A"), "accept", 0), none) ==
               {:error, :no_transport_request}

      g = admit(none, [request(device("pos"), 3)])

      assert Admission.check(dispatch(transport("A"), "accept", 0, %{"request_id" => "r0"}), g) ==
               {:error, :unknown_request}

      assert Admission.check(dispatch(transport("A"), "accept", 1), g) ==
               {:error, :stale_fulfillment_version}

      assert Admission.check(dispatch(transport("A"), "accept", 0, %{"step_id" => ""}), g) ==
               {:error, :invalid_reference}

      a = admit(g, [dispatch(transport("A"), "accept", 0)])

      assert Admission.check(dispatch(transport("A"), "accept", 0), a) ==
               {:error, {:duplicate_transport_step, "s0"}}

      assert Admission.check(dispatch(transport("A"), "reject", 1, %{"step_id" => "s0"}), a) ==
               {:error, :idempotency_conflict}

      pending = admit(a, [withdraw(device("pos"), 1)])
      assert pair(pending) == {:ready, :cancel_pending}

      assert Admission.check(dispatch(transport("A"), "in_transit", 2), pending) ==
               {:error, :cancel_pending}

      assert Admission.check(step(device("pos"), "cancel", 3), pending) ==
               {:error, :transport_pending}

      late =
        admit(g, [withdraw(device("pos"), 0), step(device("pos"), "cancel", 3)])

      assert pair(late) == {:cancelled, :withdrawn}

      assert Admission.check(dispatch(transport("A"), "accept", 1), late) ==
               {:error, :order_cancelled}

      done =
        admit(a, [
          dispatch(transport("A"), "in_transit", 1),
          dispatch(transport("A"), "delivered", 2, %{"proof" => proof("bundle")})
        ])

      assert pair(done) == {:completed, :delivered}
      assert handoff(done).proof == :crypto.hash(:sha256, "bundle")

      other =
        admit(done, [
          place(device("pos"), %{"order_id" => "o2", "cart_id" => "c2", "idempotency_key" => "k2"}),
          step(device("pos"), "accept", 0, %{"order_id" => "o2"}),
          step(device("pos"), "start_preparing", 1, %{"order_id" => "o2"}),
          step(device("pos"), "mark_ready", 2, %{"order_id" => "o2"}),
          request(device("pos"), 3, %{"order_id" => "o2", "request_id" => "r2"}),
          dispatch(transport("A"), "accept", 0, %{
            "order_id" => "o2",
            "request_id" => "r2",
            "step_id" => "x0"
          }),
          dispatch(transport("A"), "in_transit", 1, %{
            "order_id" => "o2",
            "request_id" => "r2",
            "step_id" => "x1"
          })
        ])

      for op <- ["delivered", "failed"],
          do:
            assert(
              Admission.check(
                dispatch(transport("A"), op, 2, %{
                  "order_id" => "o2",
                  "request_id" => "r2",
                  "step_id" => "x2",
                  "proof" => proof("bundle")
                }),
                other
              ) == {:error, :proof_reused}
            )
    end

    test "after acceptance, by either path, only the accepting Dispatch signs any later step" do
      g = ready() |> admit([request(device("pos"), 3)])
      accepted = admit(g, [dispatch(transport("A"), "accept", 0)])
      late = admit(g, [withdraw(device("pos"), 0), dispatch(transport("A"), "accept", 1)])
      assert {pair(late), handoff(late).accepted_by} == {{:ready, :cancel_pending}, "d1"}
      moving = admit(accepted, [dispatch(transport("A"), "in_transit", 1)])

      for {g, ops} <- [
            {accepted, ~w(reject in_transit failed cancel_confirmed delivered)},
            {late, ~w(failed cancel_confirmed reject in_transit)},
            {moving, ~w(delivered failed)}
          ],
          op <- ops do
        e = dispatch(transport("B"), op, handoff(g).fc.version)
        assert Admission.check(e, g) == {:error, :forbidden}, inspect({pair(g), op})
        assert Admission.check(%{e | signers: [transport("A")]}, g) != {:error, :forbidden}
      end
    end

    test "a proof digest closes one step only: across ops, orders, merchants and chapters" do
      bundle = proof("bundle")

      g =
        staffed()
        |> admit([grant("pos", "admin", @all, "shop2"), tgrant("C", "d3", "shop2")])
        |> then(&put_in(&1.role_keys[{"other", "governance"}], %{"gov" => @gov.pubkey}))
        |> admit([
          %{grant("pos", "admin", @all) | chapter_id: "other"},
          %{tgrant("A", "d1") | chapter_id: "other"}
        ])

      # The order, ready with an accepted request, in chapter `ch` for `merchant`.
      accepted = fn g, ch, merchant, key, id ->
        at = &%{&1 | chapter_id: ch}
        o = %{"merchant_id" => merchant, "order_id" => id}

        admit(
          g,
          Enum.map(
            [
              place(
                device("pos"),
                Map.merge(o, %{"cart_id" => "c" <> id, "idempotency_key" => "k" <> id})
              ),
              step(device("pos"), "accept", 0, o),
              step(device("pos"), "start_preparing", 1, o),
              step(device("pos"), "mark_ready", 2, o),
              request(device("pos"), 3, Map.put(o, "request_id", "r" <> id)),
              dispatch(
                transport(key),
                "accept",
                0,
                Map.merge(o, %{"request_id" => "r" <> id, "step_id" => "a" <> id})
              )
            ],
            at
          )
        )
      end

      closing = fn ch, merchant, key, id, op, v ->
        %{
          dispatch(transport(key), op, v, %{
            "merchant_id" => merchant,
            "order_id" => id,
            "request_id" => "r" <> id,
            "step_id" => op <> id,
            "proof" => bundle
          })
          | chapter_id: ch
        }
      end

      g = accepted.(g, @ch, "shop", "A", "o1")
      g = admit(g, [closing.(@ch, "shop", "A", "o1", "failed", 1)])
      assert pair(g) == {:ready, :failed_before_pickup}

      for {ch, merchant, key, id} <- [
            {@ch, "shop", "A", "o2"},
            {@ch, "shop2", "C", "o3"},
            {"other", "shop", "A", "o4"}
          ] do
        g = accepted.(g, ch, merchant, key, id)
        v = Admission.handoff(g.restaurant, ch, merchant, id).fc.version

        assert Admission.check(closing.(ch, merchant, key, id, "failed", v), g) ==
                 {:error, :proof_reused}

        g =
          admit(g, [
            %{
              dispatch(transport(key), "in_transit", v, %{
                "merchant_id" => merchant,
                "order_id" => id,
                "request_id" => "r" <> id,
                "step_id" => "t" <> id
              })
              | chapter_id: ch
            }
          ])

        assert Admission.check(closing.(ch, merchant, key, id, "delivered", v + 1), g) ==
                 {:error, :proof_reused}
      end
    end

    test "Dispatch moves the order only through the delivery-owned edges, and names itself in the order" do
      g =
        ready()
        |> admit([
          request(device("pos"), 3),
          dispatch(transport("A"), "accept", 0),
          dispatch(transport("A"), "in_transit", 1)
        ])

      assert pair(g) == {:dispatched, :in_transit}
      assert %{{:transport, "s1"} => {"d1", %{to: :dispatched}}} = order(g).seen

      failed = admit(g, [dispatch(transport("A"), "failed", 2)])
      assert pair(failed) == {:failed, :failed_in_transit}
      assert handoff(failed).reason == "nobody home"

      before =
        ready()
        |> admit([
          request(device("pos"), 3),
          dispatch(transport("A"), "accept", 0),
          dispatch(transport("A"), "failed", 1)
        ])

      assert pair(before) == {:ready, :failed_before_pickup}
      assert order(before) == order(ready())

      again = admit(before, [request(device("kds"), 3, %{"request_id" => "r2"})])
      assert pair(again) == {:ready, :requested}
      assert handoff(again).accepted_by == nil

      assert Admission.check(dispatch(transport("A"), "accept", 0), again) ==
               {:error, :unknown_request}
    end
  end

  # -- every pair, every step -------------------------------------------------

  @kitchen ~w(accept start_preparing mark_ready complete cancel dispatch fail)
  @dispatch_ops ~w(accept reject in_transit delivered failed cancel_confirmed)

  defp alphabet(g) do
    o = order(g)
    h = handoff(g)
    rid = if h, do: h.fc.request_id, else: "r-none"
    hv = if h, do: h.fc.version, else: 0
    n = System.unique_integer([:positive])

    Enum.map(
      @kitchen,
      &{{:kitchen, String.to_existing_atom(&1)},
       step(device("pos"), &1, o.version, %{"command_id" => "c#{n}"})}
    ) ++
      [
        {:request, request(device("pos"), o.version, %{"request_id" => "r#{n}"})},
        {:withdraw, withdraw(device("pos"), hv, %{"request_id" => rid, "command_id" => "w#{n}"})}
      ] ++
      Enum.map(
        @dispatch_ops,
        &{{:dispatch, String.to_existing_atom(&1)},
         dispatch(transport("A"), &1, hv, %{"request_id" => rid, "step_id" => "s#{n}"})}
      )
  end

  defp explore do
    start = admit(staffed(), [place(device("pos"))])

    Stream.iterate({%{pair(start) => start}, [start], MapSet.new()}, fn {reps, frontier, steps} ->
      results =
        for g <- frontier, {op, e} <- alphabet(g), Admission.check(e, g) == :ok do
          n = %{g | restaurant: Admission.fold(e, g)}
          {n, {pair(g), op, pair(n)}}
        end

      fresh =
        results
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&Map.has_key?(reps, pair(&1)))
        |> Enum.uniq_by(&pair/1)

      {Map.merge(reps, Map.new(fresh, &{pair(&1), &1})), fresh,
       MapSet.union(steps, MapSet.new(results, &elem(&1, 1)))}
    end)
    |> Enum.find(fn {_, frontier, _} -> frontier == [] end)
  end

  test "BFS over check/2 and fold/2: the reached pairs are the coupled pairs, the admitted steps are the rows, and the refusals are pinned" do
    {reps, _, steps} = explore()

    coupled =
      for s <- Coupling.states(),
          v <- Coupling.views(),
          Coupling.coupled?(:delivery, s, v),
          do: {s, v}

    assert MapSet.new(Map.keys(reps)) == MapSet.new(coupled)
    assert steps == MapSet.new(Coupling.rows(), fn {from, _, op, to, _} -> {from, op, to} end)

    tally =
      for {_, g} <- reps, {op, e} <- alphabet(g), reduce: %{} do
        acc ->
          case Admission.check(e, g) do
            :ok ->
              n = %{g | restaurant: Admission.fold(e, g)}
              assert {:ok, {_, _, ^op, to, _}} = Coupling.row(pair(g), op)
              assert pair(n) == to
              Map.update(acc, :ok, 1, &(&1 + 1))

            {:error, reason} when is_atom(reason) ->
              Map.update(acc, reason, 1, &(&1 + 1))
          end
      end

    assert tally == %{
             ok: 30,
             invalid_transition: 109,
             terminal_fulfillment: 56,
             no_transport_request: 30,
             invalid_fulfillment_transition: 15,
             order_not_ready: 11,
             delivery_owned: 10,
             unknown_handoff: 5,
             transport_already_requested: 4,
             transport_not_accepted: 4,
             delivery_without_transport_start: 3,
             transport_pending: 3,
             transport_already_accepted: 2,
             cancel_pending: 1,
             order_cancelled: 1,
             transport_started: 1
           }
  end

  # Representative FulfillmentCore states per view, by BFS over the reducer.
  defp fc_reps do
    {:ok, start} = FulfillmentCore.new("shop", "r1", "o1", "restaurant-courier")

    ops = [
      {:commerce, :cancel} | Enum.map(@dispatch_ops, &{:dispatch, String.to_existing_atom(&1)})
    ]

    Stream.iterate({%{Coupling.view(start) => start}, [start]}, fn {seen, frontier} ->
      next =
        for fc <- frontier,
            {actor, op} <- ops,
            event = %{
              id: "e#{fc.version}",
              expected_version: fc.version,
              op: op,
              transport_ref: "t",
              reason: "r",
              proof_ref: "p"
            },
            {:ok, n, :accepted} <- [FulfillmentCore.apply(fc, "shop", actor, event)],
            not Map.has_key?(seen, Coupling.view(n)),
            do: n

      next = Enum.uniq_by(next, &Coupling.view/1)
      {Map.merge(seen, Map.new(next, &{Coupling.view(&1), &1})), next}
    end)
    |> Enum.find(fn {_, frontier} -> frontier == [] end)
    |> elem(0)
  end

  test "an injected uncoupled pair admits no order event and raises on none" do
    reps = fc_reps()

    for f <- [:delivery, :pickup, :dine_in],
        s <- Coupling.states(),
        v <- Coupling.views(),
        not Coupling.coupled?(f, s, v) do
      base = ready(staffed(), %{"fulfillment" => Atom.to_string(f)})
      key = {@ch, "shop", "o1"}

      restaurant =
        base.restaurant
        |> put_in([:merchants, {@ch, "shop"}, :orders, "o1", :state], s)
        |> put_in(
          [:handoffs],
          if(v == :none,
            do: %{},
            else: %{
              key => %{
                fc: reps[v],
                requested_by: "device-pos",
                accepted_by: nil,
                reason: nil,
                proof: nil
              }
            }
          )
        )

      g = %{base | restaurant: restaurant}

      for {op, e} <- alphabet(g),
          do: assert(match?({:error, _}, Admission.check(e, g)), inspect({f, s, v, op}))
    end
  end

  test "history before this slice folds unchanged and leaves the transport state empty" do
    g =
      gate([
        grant("pos", "admin", @all),
        grant("kds", "staff", @all),
        place(device("pos"), %{"delivery" => %{}}),
        place(device("pos"), %{
          "order_id" => "o2",
          "cart_id" => "c2",
          "idempotency_key" => "k2",
          "fulfillment" => "pickup"
        }),
        step(device("pos"), "accept", 0),
        step(device("kds"), "start_preparing", 1),
        step(device("kds"), "mark_ready", 2),
        step(device("pos"), "cancel", 3),
        step(device("pos"), "accept", 0, %{"order_id" => "o2"})
      ])

    assert Enum.map(Admission.orders(g.restaurant, @ch, "shop"), &{&1.id, &1.state}) ==
             [{"o1", :cancelled}, {"o2", :accepted}]

    assert Map.take(g.restaurant, [:transport_keys, :handoffs, :requests, :proofs]) ==
             %{transport_keys: %{}, handoffs: %{}, requests: %{}, proofs: %{}}
  end

  test "the board view carries the address, the handoff and the actions the pair allows" do
    g = ready()
    [row] = Admission.orders(g.restaurant, @ch, "shop")

    assert {row.delivery, row.handoff, row.handoff_actions, row.actions} ==
             {%{"address" => "1 Main St"}, nil, [:request_transport], [:cancel]}

    g = admit(g, [request(device("pos"), 3), dispatch(transport("A"), "accept", 0)])
    [row] = Admission.orders(g.restaurant, @ch, "shop")

    assert {row.handoff.view, row.handoff.transport_ref, row.handoff.accepted_by} ==
             {:accepted, "trip-1", "d1"}

    assert {row.handoff_actions, row.actions} == {[:withdraw_transport], []}

    g = admit(g, [withdraw(device("pos"), 1)])
    [row] = Admission.orders(g.restaurant, @ch, "shop")
    assert {row.handoff.view, row.handoff_actions, row.actions} == {:cancel_pending, [], []}

    g = admit(g, [dispatch(transport("A"), "cancel_confirmed", 2)])
    [row] = Admission.orders(g.restaurant, @ch, "shop")

    assert {row.handoff.view, row.handoff_actions, row.actions} ==
             {:cancelled, [], [:cancel]}

    pickup =
      admit(staffed(), [place(device("pos"), %{"fulfillment" => "pickup"})])

    [row] = Admission.orders(pickup.restaurant, @ch, "shop")
    assert {row.handoff, row.handoff_actions} == {nil, []}
  end

  # -- properties -------------------------------------------------------------

  # Restaurant events and forged Dispatch steps; with `dispatch?`, also Dispatch
  # steps by either key at any version, and (weighted) a step the relation
  # allows from the current pair, other than the kitchen cancel, signed by the
  # restaurant or by the accepting Dispatch at the current version, so runs
  # reach pickup, delivery, failure and a pending withdrawal.
  defp event_gen(dispatch? \\ true) do
    restaurant = [
      {2, tuple({constant(:step), member_of(~w(pos kds bot)), member_of(@kitchen)})},
      {1, tuple({constant(:request), member_of(~w(pos kds bot))})},
      {1, tuple({constant(:withdraw), member_of(~w(pos kds bot))})},
      {1, tuple({constant(:forged), member_of(~w(pos kds)), member_of(@dispatch_ops)})}
    ]

    dispatch = [
      {1, tuple({constant(:dispatch), member_of(~w(A B)), member_of(@dispatch_ops)})},
      {5, tuple({constant(:progress), integer(0..5)})}
    ]

    frequency(if dispatch?, do: restaurant ++ dispatch, else: restaurant)
  end

  defp concrete(g, spec, skew, reuse) do
    o = order(g)
    h = handoff(g)
    rid = if h, do: h.fc.request_id, else: "r-none"
    hv = if(h, do: h.fc.version, else: 0) + skew
    id = if reuse, do: "x", else: "i#{System.unique_integer([:positive])}"

    case spec do
      {:progress, n} ->
        choices =
          for {from, _, op, _, _} <- Coupling.rows(),
              from == pair(g) and op != {:kitchen, :cancel},
              do: op

        key = %{"d1" => "A", "d2" => "B"}[h && h.accepted_by] || "A"
        hv = if(h, do: h.fc.version, else: 0)
        fresh = "p#{System.unique_integer([:positive])}"

        case if(choices == [], do: nil, else: Enum.at(choices, rem(n, length(choices)))) do
          nil ->
            step(device("pos"), "accept", o.version, %{"command_id" => fresh})

          {:kitchen, a} ->
            step(device("pos"), Atom.to_string(a), o.version, %{"command_id" => fresh})

          :request ->
            request(device("pos"), o.version, %{"request_id" => fresh})

          :withdraw ->
            withdraw(device("pos"), hv, %{"request_id" => rid, "command_id" => fresh})

          {:dispatch, op} ->
            dispatch(transport(key), Atom.to_string(op), hv, %{
              "request_id" => rid,
              "step_id" => fresh
            })
        end

      {:step, dev, action} ->
        step(device(dev), action, o.version + skew, %{"command_id" => id})

      {:request, dev} ->
        request(device(dev), o.version + skew, %{"request_id" => if(reuse, do: rid, else: id)})

      {:withdraw, dev} ->
        withdraw(device(dev), hv, %{"request_id" => rid, "command_id" => id})

      {:dispatch, key, op} ->
        dispatch(transport(key), op, hv, %{"request_id" => rid, "step_id" => id})

      {:forged, dev, op} ->
        dispatch(%{device(dev) | role: "dispatch_transport"}, op, hv, %{
          "request_id" => rid,
          "step_id" => id
        })
    end
  end

  property "only Dispatch's transport keys move a delivery order into a delivery-owned state or a Dispatch view" do
    check all(
            specs <- list_of(tuple({event_gen(false), integer(-1..1), boolean()}), max_length: 25),
            max_runs: 200
          ) do
      g =
        Enum.reduce(specs, ready(), fn {spec, skew, reuse}, g ->
          e = concrete(g, spec, skew, reuse)
          if Admission.check(e, g) == :ok, do: %{g | restaurant: Admission.fold(e, g)}, else: g
        end)

      {s, v} = pair(g)
      refute s in @owned
      assert v in [:none, :requested, :withdrawn]
    end
  end

  property "interleavings: the pair stays coupled, and order and handoff are exactly their reducers' replays" do
    check all(
            specs <- list_of(tuple({event_gen(), integer(-1..1), boolean()}), max_length: 25),
            max_runs: 200
          ) do
      Enum.reduce(
        specs,
        {ready(), [{:placed, :accepted}, {:accepted, :preparing}, {:preparing, :ready}], nil},
        fn {spec, skew, reuse}, {g, moves, fc_log} ->
          e = concrete(g, spec, skew, reuse)

          case Admission.check(e, g) do
            :ok ->
              n = %{g | restaurant: Admission.fold(e, g)}
              reach(e, pair(g))

              if e.type == "RestaurantTransportStepV1" and handoff(g).accepted_by,
                do: assert(handoff(g).accepted_by == handoff(n).accepted_by)

              assert Coupling.coupled?(
                       :delivery,
                       order(n).state,
                       Coupling.view(handoff(n) && handoff(n).fc)
                     )

              moves =
                if order(n).state != order(g).state,
                  do: moves ++ [{order(g).state, order(n).state}],
                  else: moves

              assert Kitchen.replay(:delivery, moves) == {:ok, order(n).state}

              fc_log =
                case {e.type, e.payload} do
                  {"RestaurantTransportRequestedV1", p} ->
                    {p["request_id"], []}

                  {"RestaurantTransportCancelRequestedV1", p} ->
                    {rid, log} = fc_log

                    {rid,
                     log ++
                       [
                         {:commerce,
                          %{
                            id: p["command_id"],
                            expected_version: p["expected_version"],
                            op: :cancel,
                            reason: p["reason"]
                          }}
                       ]}

                  {"RestaurantTransportStepV1", p} ->
                    {rid, log} = fc_log
                    {rid, log ++ [{:dispatch, fc_event(p)}]}

                  _ ->
                    fc_log
                end

              with {rid, log} <- fc_log do
                {:ok, fc0} = FulfillmentCore.new("shop", rid, "o1", "restaurant-courier")
                assert FulfillmentCore.replay(fc0, "shop", log) == {:ok, handoff(n).fc}
              end

              for {k, binding} <- order(n).seen do
                case k do
                  {:transport, _} ->
                    assert {"d" <> _, %{to: _}} = binding

                  id when is_binary(id) ->
                    assert {"device-" <> _, actor, _} = binding
                    assert actor in [:admin, :staff]
                end
              end

              {n, moves, fc_log}

            {:error, _} ->
              assert_raise MatchError, fn -> Admission.fold(e, g) end
              {g, moves, fc_log}
          end
        end
      )
    end

    # The oracles above ran on every kind of Dispatch step, not just the easy ones.
    for op <- @dispatch_ops, do: assert(reached(op) > 0, op)

    # Floors well under the minimum over 30 seeds (15 and 41).
    assert reached("delivered") + reached("failed", [:in_transit]) >= 5

    assert reached("cancel_confirmed", [:cancel_pending]) + reached("failed", [:cancel_pending]) >=
             10
  end

  # Counts what the interleavings admitted, by event and source view.
  defp reach(%{type: "RestaurantTransportStepV1", payload: %{"op" => op}}, {_, view}),
    do: Process.put({:reach, op, view}, Process.get({:reach, op, view}, 0) + 1)

  defp reach(_, _), do: :ok

  defp reached(op, views \\ Coupling.views()),
    do: Enum.sum(for v <- views, do: Process.get({:reach, op, v}, 0))

  defp fc_event(p) do
    {:ok, op, _} = Coupling.dispatch_fields(p["op"])

    %{id: p["step_id"], expected_version: p["expected_version"], op: op}
    |> then(
      &if(p["transport_ref"], do: Map.put(&1, :transport_ref, p["transport_ref"]), else: &1)
    )
    |> then(&if(p["reason"], do: Map.put(&1, :reason, p["reason"]), else: &1))
    |> then(fn e ->
      case p["proof"] do
        {:bytes, digest} -> Map.put(e, :proof_ref, Base.encode16(digest, case: :lower))
        nil -> e
      end
    end)
  end

  test "with a handoff in any view, a step's admission is the kitchen's outcome except a cancel while transport is live" do
    {reps, _, _} = explore()
    actors = %{"pos" => :admin, "kds" => :staff, "bot" => :system}

    outcomes =
      for {p, g} <- reps, dev <- ~w(pos kds bot), action <- @kitchen, skew <- -1..1 do
        o = order(g)

        trusted = %{
          merchant: "shop",
          order_id: "o1",
          principal: "device-" <> dev,
          actor: actors[dev],
          granted: true,
          allowed_actions: Enum.map(@all, &String.to_existing_atom/1)
        }

        cmd = %{
          id: "k",
          expected_version: o.version + skew,
          action: String.to_existing_atom(action),
          reason: "because"
        }

        expected =
          case Kitchen.apply(o, trusted, cmd) do
            {:ok, _, :accepted} ->
              if elem(p, 1) in Coupling.live(), do: {:error, :transport_pending}, else: :ok

            {:error, _} = error ->
              error
          end

        e = step(device(dev), action, o.version + skew, %{"command_id" => "k"})
        assert Admission.check(e, g) == expected, inspect({p, dev, action, skew})
        expected
      end

    assert length(outcomes) == 19 * 3 * 7 * 3
    assert Enum.count(outcomes, &(&1 == {:error, :transport_pending})) == 6
    assert Enum.count(outcomes, &(&1 == :ok)) == 22
  end
end
