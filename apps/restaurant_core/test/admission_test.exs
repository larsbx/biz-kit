defmodule RestaurantCore.AdmissionTest do
  @moduledoc """
  Admission of signed restaurant events, as the substrate's single appender
  runs it: the trusted context comes from a governance-signed device grant,
  never from the request, and the outcome is the pure reducers' outcome.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestaurantCore.{Admission, Kitchen}

  @ch "chapter"
  @gov %{role: "governance", key_id: "gov", pubkey: :binary.copy(<<1>>, 32)}

  defp device(id), do: %{role: "restaurant_device", key_id: id, pubkey: :crypto.hash(:sha256, id)}

  defp env(type, signer, payload),
    do: %{type: type, chapter_id: @ch, signers: [signer], payload: payload}

  defp grant(id, actor, actions, merchant \\ "shop"),
    do:
      env("RestaurantDeviceGrantedV1", @gov, %{
        "merchant_id" => merchant,
        "device_id" => "device-" <> id,
        "key_id" => id,
        "pubkey" => {:bytes, device(id).pubkey},
        "actor" => actor,
        "actions" => actions
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
            "fulfillment" => "pickup",
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
            "total_minor" => 2500,
            "adjustments" => %{
              "discount_total" => 0,
              "tax_total" => 0,
              "delivery_fee" => 0,
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

  @all ~w(checkout accept start_preparing mark_ready complete cancel dispatch fail)

  defp gate(events) do
    Enum.reduce(
      events,
      %{
        role_keys: %{{@ch, "governance"} => %{"gov" => @gov.pubkey}},
        restaurant: Admission.init()
      },
      fn e, g ->
        assert Admission.check(e, g) == :ok, inspect({e.type, Admission.check(e, g)})
        %{g | restaurant: Admission.fold(e, g)}
      end
    )
  end

  defp admin_gate,
    do:
      gate([
        grant("pos", "admin", @all),
        grant("kds", "staff", @all),
        grant("bot", "system", @all)
      ])

  test "every registered type is one of the four, each signed by one role" do
    assert Map.keys(Admission.event_types()) |> Enum.sort() ==
             ~w(RestaurantDeviceGrantedV1 RestaurantMenuItemPutV1 RestaurantOrderPlacedV1 RestaurantOrderStepV1)

    for {_, spec} <- Admission.event_types(), do: assert([_] = spec.required_roles)
  end

  defp menu_put(signer, version, extra \\ %{}),
    do:
      env(
        "RestaurantMenuItemPutV1",
        signer,
        Map.merge(
          %{
            "merchant_id" => "shop",
            "expected_version" => version,
            "item_id" => "margherita",
            "name" => "Margherita",
            "sku" => "MARG",
            "price_minor" => 1250,
            "currency" => "USD",
            "visibility" => "published",
            "discounts" => []
          },
          extra
        )
      )

  test "menu items are governance facts, versioned per merchant (D6)" do
    g = admin_gate()
    assert Admission.menu(g.restaurant, @ch, "shop") == %{version: 0, items: %{}}

    # A device, even an admin one, cannot edit the menu; nor an undeclared key.
    assert Admission.check(menu_put(device("pos"), 0), g) ==
             {:error, :restaurant_governance_not_declared}

    assert Admission.check(menu_put(%{@gov | key_id: "other"}, 0), g) ==
             {:error, :restaurant_governance_not_declared}

    g1 = %{g | restaurant: Admission.fold(menu_put(@gov, 0), g)}

    assert %{version: 1, items: %{"margherita" => %{price_minor: 1250}}} =
             Admission.menu(g1.restaurant, @ch, "shop")

    assert Admission.check(menu_put(@gov, 0, %{"price_minor" => 1300}), g1) ==
             {:error, :stale_menu_version}

    assert Admission.check(menu_put(@gov, 1, %{"price_minor" => 0}), g1) ==
             {:error, :invalid_menu_item}

    assert Admission.check(menu_put(@gov, 1, %{"item_id" => "p2"}), g1) ==
             {:error, :duplicate_sku}

    # Menus are per merchant: another merchant starts at version 0.
    assert Admission.check(menu_put(@gov, 0, %{"merchant_id" => "cafe"}), g1) == :ok
    assert Admission.menu(g1.restaurant, @ch, "cafe") == %{version: 0, items: %{}}
  end

  test "a grant needs a declared governance key and a well-formed actor and action list" do
    g = gate([])
    rogue = %{@gov | pubkey: :binary.copy(<<2>>, 32)}

    assert Admission.check(%{grant("pos", "admin", @all) | signers: [rogue]}, g) ==
             {:error, :restaurant_governance_not_declared}

    assert Admission.check(grant("pos", "root", @all), g) == {:error, :invalid_restaurant_grant}

    assert Admission.check(grant("pos", "admin", ["teleport"]), g) ==
             {:error, :invalid_restaurant_grant}

    assert Admission.check(grant("pos", "admin", "accept"), g) ==
             {:error, :invalid_restaurant_grant}

    g = gate([grant("pos", "admin", @all)])

    assert Admission.check(grant("pos", "staff", ["accept"]), g) ==
             {:error, :restaurant_key_already_granted}

    assert Admission.check(grant("pos", "staff", ["accept"], "other-shop"), g) == :ok
  end

  test "checkout places one order per cart and per channel key, and only by a device granted checkout" do
    g = admin_gate()
    assert Admission.check(place(device("ghost")), g) == {:error, :forbidden}

    assert Admission.check(place(%{device("pos") | pubkey: device("kds").pubkey}), g) ==
             {:error, :forbidden}

    g2 = gate([grant("kds", "staff", ["accept"])])
    assert Admission.check(place(device("kds")), g2) == {:error, :forbidden}

    placed = %{g | restaurant: Admission.fold(place(device("pos")), g)}
    assert Admission.state(placed.restaurant, @ch, "shop", "o1").state == :placed

    assert Admission.check(place(device("bot"), %{"order_id" => "o2"}), placed) ==
             {:error, {:duplicate_checkout, "o1"}}

    assert Admission.check(
             place(device("pos"), %{"order_id" => "o2", "idempotency_key" => "k2"}),
             placed
           ) ==
             {:error, :inactive_cart}

    assert Admission.check(
             place(device("pos"), %{"cart_id" => "c2", "idempotency_key" => "k2"}),
             placed
           ) ==
             {:error, :order_exists}

    assert Admission.check(place(device("pos"), %{"fulfillment" => "ship"}), g) ==
             {:error, :invalid_checkout_command}

    assert Admission.check(place(device("pos"), %{"currency" => "usd"}), g) ==
             {:error, :invalid_checkout_command}

    assert Admission.check(place(device("pos"), %{"total_minor" => -1}), g) ==
             {:error, :invalid_checkout_command}

    assert Admission.check(place(device("pos"), %{"lines" => [%{"unit_minor" => 1}]}), g) ==
             {:error, :invalid_checkout_command}

    assert Admission.check(place(device("pos"), %{"fulfillment" => "delivery"}), g) ==
             {:error, :delivery_required}

    assert Admission.check(
             place(device("pos"), %{"fulfillment" => "delivery", "delivery" => %{}}),
             g
           ) == :ok
  end

  test "a placed snapshot must add up (I₂), in integers, with each discount within its line" do
    g = admin_gate()

    line = fn d ->
      %{"name" => "M", "unit_minor" => 1250, "quantity" => 2, "discount_minor" => d}
    end

    adj = fn tax ->
      %{"discount_total" => 100, "tax_total" => tax, "delivery_fee" => 0, "tip" => 50}
    end

    # 2500 − 300 = 2200; 2200 − 100 + 181 + 0 + 50 = 2331
    good = %{
      "lines" => [line.(300)],
      "subtotal_minor" => 2200,
      "total_minor" => 2331,
      "adjustments" => adj.(181)
    }

    assert Admission.check(place(device("pos"), good), g) == :ok

    for bad <- [
          %{good | "subtotal_minor" => 2500},
          %{good | "total_minor" => 2332},
          %{good | "lines" => [line.(-1)], "subtotal_minor" => 2501, "total_minor" => 2632},
          %{good | "lines" => [line.(2501)], "subtotal_minor" => -1, "total_minor" => 130},
          %{good | "adjustments" => adj.(0), "total_minor" => 2150, "subtotal_minor" => 0}
        ] do
      assert Admission.check(place(device("pos"), bad), g) == {:error, :invalid_checkout_command},
             inspect(bad)
    end
  end

  test "steps are authorized by the grant, not the request; an unknown order is indistinguishable" do
    g = gate([grant("pos", "admin", @all), grant("bot", "system", @all)])
    g = %{g | restaurant: Admission.fold(place(device("pos")), g)}

    assert Admission.check(step(device("bot"), "accept", 0), g) == {:error, :forbidden}

    assert Admission.check(step(device("pos"), "accept", 0, %{"order_id" => "nope"}), g) ==
             {:error, :forbidden}

    assert Admission.check(step(device("pos"), "teleport", 0), g) == {:error, :forbidden}
    assert Admission.check(step(device("pos"), "accept", 1), g) == {:error, :stale_order_version}

    g = %{g | restaurant: Admission.fold(step(device("pos"), "accept", 0), g)}

    assert Admission.check(step(device("pos"), "accept", 0), g) ==
             {:error, {:duplicate_command, "c0"}}

    assert Admission.check(step(device("pos"), "cancel", 1, %{"reason" => ""}), g) ==
             {:error, :reason_required}
  end

  test "a device acts only for its own merchant, and the binding names the granted device" do
    g = admin_gate()

    assert Admission.check(place(device("pos"), %{"merchant_id" => "other-shop"}), g) ==
             {:error, :forbidden}

    g = %{g | restaurant: Admission.fold(place(device("pos")), g)}
    e = step(device("kds"), "accept", 0, %{"principal_id" => "mallory"})
    g = %{g | restaurant: Admission.fold(e, g)}

    assert [{"device-kds", :staff, _}] =
             Map.values(Admission.state(g.restaurant, @ch, "shop", "o1").seen)
  end

  test "the board view joins each order's lifecycle with its signed snapshot" do
    g = admin_gate()
    assert Admission.orders(g.restaurant, @ch, "shop") == []

    g =
      Enum.reduce(
        [
          place(device("pos"), %{"order_id" => "o2", "cart_id" => "c2", "idempotency_key" => "k2"}),
          place(device("pos"), %{"pickup_name" => "Ada"}),
          step(device("pos"), "accept", 0)
        ],
        g,
        fn e, g -> %{g | restaurant: Admission.fold(e, g)} end
      )

    assert [first, second] = Admission.orders(g.restaurant, @ch, "shop")
    assert {first.id, first.state, first.version, first.total} == {"o1", :accepted, 1, 2500}
    assert first.actions == [:start_preparing, :cancel]
    assert [%{"name" => "Margherita", "quantity" => 2}] = first.lines
    assert {second.id, second.state, second.actions} == {"o2", :placed, [:accept, :cancel]}
    assert second.principal == "ada" and second.fulfillment == :pickup
    assert {first.pickup_name, second.pickup_name} == {"Ada", nil}

    assert Admission.check(
             place(device("pos"), %{
               "order_id" => "o3",
               "cart_id" => "c3",
               "idempotency_key" => "k3",
               "pickup_name" => " "
             }),
             g
           ) ==
             {:error, :invalid_checkout_command}
  end

  test "a delivery order's hand-off is never an order step" do
    g = admin_gate()
    p = place(device("pos"), %{"fulfillment" => "delivery", "delivery" => %{}})

    g =
      Enum.reduce(
        [
          p,
          step(device("pos"), "accept", 0),
          step(device("pos"), "start_preparing", 1),
          step(device("pos"), "mark_ready", 2)
        ],
        g,
        fn e, g ->
          assert Admission.check(e, g) == :ok
          %{g | restaurant: Admission.fold(e, g)}
        end
      )

    assert Admission.check(step(device("pos"), "dispatch", 3), g) == {:error, :delivery_owned}
    assert Admission.check(step(device("bot"), "complete", 3), g) == {:error, :invalid_transition}
  end

  property "admission refines the kitchen reducer: same outcome, same state, for any step sequence" do
    check all(
            fulfillment <- member_of(~w(pickup dine_in delivery)),
            steps <-
              list_of(
                {member_of(~w(pos kds bot)),
                 member_of(~w(accept start_preparing mark_ready complete cancel dispatch fail)),
                 integer(-1..1)},
                max_length: 8
              )
          ) do
      g = admin_gate()
      p = place(device("pos"), %{"fulfillment" => fulfillment, "delivery" => %{}})
      g = %{g | restaurant: Admission.fold(p, g)}
      actors = %{"pos" => :admin, "kds" => :staff, "bot" => :system}
      {:ok, order} = Kitchen.new("shop", "o1", String.to_existing_atom(fulfillment))

      Enum.reduce(Enum.with_index(steps), {g, order}, fn {{dev, action, skew}, i}, {g, order} ->
        version = order.version + skew
        e = step(device(dev), action, version, %{"command_id" => "c#{i}"})

        trusted = %{
          merchant: "shop",
          order_id: "o1",
          principal: "device-" <> dev,
          actor: actors[dev],
          granted: true,
          allowed_actions: Enum.map(@all, &String.to_existing_atom/1)
        }

        cmd = %{
          id: "c#{i}",
          expected_version: version,
          action: String.to_existing_atom(action),
          reason: "because"
        }

        case Kitchen.apply(order, trusted, cmd) do
          {:ok, next, :accepted} ->
            assert Admission.check(e, g) == :ok
            g = %{g | restaurant: Admission.fold(e, g)}
            assert Admission.state(g.restaurant, @ch, "shop", "o1") == next
            {g, next}

          {:error, reason} ->
            assert Admission.check(e, g) == {:error, reason}
            {g, order}
        end
      end)
    end
  end
end
