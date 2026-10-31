defmodule CommerceCore.CheckoutSafetyTest do
  use ExUnit.Case, async: true
  alias CommerceCore.{Checkout, Tax}

  @path Path.expand("fixtures/eatsbot_characterization/checkout.jsonl", __DIR__)
  @hash "75ab2f968d726b2cdb570490072a5bff4829e92bfca1ec4427ef16b88c3465f8"
  defp m(n), do: Money.from_integer(n, :USD)

  defp line(name, price, qty),
    do: %{name: name, unit_price: m(price), quantity: qty, discount: m(0)}

  defp cart(lines), do: %{principal: "ada", status: :active, currency: :USD, lines: lines}

  defp trusted(cart),
    do: %{merchant: "shop", principal: "ada", cart_id: cart, granted: true, operation: :checkout}

  defp command(cart, key, extras \\ %{}) do
    Map.merge(
      %{
        cart_id: cart,
        channel: :web,
        idempotency_key: key,
        fulfillment: :pickup,
        adjustments: %{discount_total: m(0), tax_total: m(0), delivery_fee: m(0), tip: m(0)}
      },
      extras
    )
  end

  defp initial do
    basket = cart([line("Margherita", 1250, 2), line("Pepperoni", 1400, 1)])

    {:ok, state} =
      Checkout.new("shop", %{
        "pickup" => basket,
        "other" => basket,
        "telegram" => basket,
        "empty" => cart([]),
        "missing-details" => basket,
        "delivery" => cart([line("Margherita", 1250, 1)]),
        "dine-in" => cart([line("Pepperoni", 1400, 3)])
      })

    state
  end

  # Inputs reconstructed from the pinned orders_characterization_test.exs, never
  # from expected output prices. IDs replace UUIDs; there is no database writer.
  defp scenarios do
    [
      {"pickup basket", command("pickup", "k-1")},
      {"same cart, same key, again", command("pickup", "k-1")},
      {"same key, another cart", command("other", "k-1")},
      {"same key, other channel", command("telegram", "k-1", %{channel: :telegram})},
      {"completed cart, new key", command("pickup", "k-2")},
      {"empty cart", command("empty", "k-3")},
      {"unknown cart", command("unknown", "k-4")},
      {"delivery without details", command("missing-details", "k-5", %{fulfillment: :delivery})},
      {"delivery with tip and fee",
       command("delivery", "k-d", %{
         fulfillment: :delivery,
         delivery: %{},
         adjustments: %{discount_total: m(0), tax_total: m(0), delivery_fee: m(450), tip: m(300)}
       })},
      {"delivery, same key again",
       command("delivery", "k-d", %{fulfillment: :delivery, delivery: %{}})},
      {"dine-in", command("dine-in", "k-6", %{fulfillment: :dine_in})}
    ]
  end

  test "all 11 pinned scenarios: prices, snapshots, cart completion, delivery cardinality and refusals" do
    bytes = File.read!(@path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @hash
    rows = bytes |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)
    assert length(rows) == 11
    assert Enum.map(rows, & &1["scenario"]) == Enum.map(scenarios(), &elem(&1, 0))

    {final, _} =
      Enum.zip(rows, scenarios())
      |> Enum.reduce({initial(), %{}}, fn {row, {name, cmd}}, {state, seen} ->
        case Checkout.apply(state, trusted(cmd.cart_id), cmd) do
          {:ok, updated, order, status} ->
            recorded = row["result"]["ok"]
            assert recorded != nil, name
            assert order.financial_status == :unconfirmed
            assert updated.carts[cmd.cart_id].status == :completed
            assert Enum.count(Map.values(updated.orders), &(&1.cart_id == cmd.cart_id)) == 1

            fields =
              ~w(channel currency fulfillment state lines subtotal total state_changes discount_total tax_total delivery_fee tip)

            actual =
              order
              |> Map.take([:channel, :currency, :fulfillment, :state, :lines, :subtotal, :total])
              |> Map.merge(order.adjustments)
              |> Map.put(:state_changes, length(order.state_changes))
              |> encode()

            assert actual == Map.take(recorded, fields), name
            assert order.delivery_request == :required == (recorded["delivery"] == "Init")
            assert order.delivery_request == :required == recorded["has_delivery_key"]
            key = {cmd.channel, cmd.idempotency_key}

            if Map.has_key?(seen, key) do
              assert status == :duplicate
              assert order === seen[key]
              assert updated === state
            else
              assert status == :accepted
            end

            if row["same_order"], do: assert(order === seen[key])
            {updated, Map.put(seen, key, order)}

          {:error, reason} ->
            assert %{"error" => %{"errors" => [error]}} = row["result"]

            assert {error["field"], error["message"]} ==
                     Map.fetch!(
                       %{
                         idempotency_conflict:
                           {"idempotency_key", "was already used for another cart"},
                         inactive_cart: {"cart_id", "cart is not active"},
                         empty_cart: {"cart_id", "cart is empty"},
                         unknown_cart: {"cart_id", "cart does not exist"},
                         delivery_required: {"delivery", "is required for a delivery order"}
                       },
                       reason
                     )

            {state, seen}
        end
      end)

    assert map_size(final.orders) == 4
  end

  test "ownership and current per-cart authorization precede all protected observations" do
    state = initial()
    cmd = command("pickup", "k")

    for ctx <- [
          nil,
          %{trusted("pickup") | operation: :refund},
          %{trusted("pickup") | granted: false},
          %{trusted("pickup") | principal: "mallory"},
          %{trusted("pickup") | merchant: "other"},
          trusted("other")
        ] do
      assert Checkout.apply(state, ctx, cmd) == {:error, :forbidden}
    end

    for cart <- ["unknown", "empty", "pickup"] do
      assert Checkout.apply(:unreadable, %{trusted(cart) | granted: false}, command(cart, "k")) ==
               {:error, :forbidden}
    end

    {:ok, state, _, :accepted} = Checkout.apply(state, trusted("pickup"), cmd)

    assert Checkout.apply(state, %{trusted("pickup") | granted: false}, cmd) ==
             {:error, :forbidden}

    assert Checkout.apply(state, %{trusted("pickup") | principal: "mallory"}, cmd) ==
             {:error, :forbidden}
  end

  test "replay preserves the first price snapshot; checkout intent and tax reversal never settle" do
    state = initial()
    cmd = command("pickup", "k") |> Map.put(:financial_status, :settled)
    {:ok, state, order, :accepted} = Checkout.apply(state, trusted("pickup"), cmd)
    changed = %{cmd | adjustments: %{cmd.adjustments | tip: m(9999)}, fulfillment: :delivery}
    assert {:ok, ^state, ^order, :duplicate} = Checkout.apply(state, trusted("pickup"), changed)
    {:ok, reversal} = Tax.reverse(m(89), m(1089), m(0), m(1089))
    assert reversal == m(89)
    assert order.financial_status == :unconfirmed
    refute Map.has_key?(order, :settlement)
    refute Map.has_key?(order, :refund)

    assert {:error, :inactive_cart} =
             Checkout.apply(state, trusted("pickup"), command("pickup", "new-key"))

    assert {:error, :inactive_cart} =
             Checkout.apply(
               state,
               trusted("pickup"),
               command("pickup", "new-key", %{channel: :telegram})
             )

    other_owner = put_in(state.carts["other"].principal, "mallory")

    assert Checkout.apply(
             other_owner,
             %{trusted("other") | principal: "mallory"},
             command("other", "k")
           ) == {:error, :forbidden}

    {:ok, blank} = Checkout.new("another-shop", %{"pickup" => cart([line("Pepperoni", 1400, 1)])})

    assert {:ok, _, _, :accepted} =
             Checkout.apply(blank, %{trusted("pickup") | merchant: "another-shop"}, cmd)
  end

  test "malformed delivery, amounts and unsupported commands refuse without effects" do
    state = initial()
    cmd = command("pickup", "k")

    assert Checkout.apply(state, trusted("pickup"), Map.delete(cmd, :adjustments)) ==
             {:error, :invalid_checkout_command}

    assert Checkout.apply(state, trusted("pickup"), %{cmd | adjustments: %{}}) ==
             {:error, :invalid_adjustments}

    assert Checkout.apply(state, trusted("pickup"), %{cmd | channel: :unknown}) ==
             {:error, :invalid_checkout_command}

    assert Checkout.apply(state, trusted("pickup"), %{cmd | fulfillment: :unknown}) ==
             {:error, :invalid_fulfillment}

    assert Checkout.apply(state, trusted("pickup"), %{
             cmd
             | adjustments: %{cmd.adjustments | tip: m(-1)}
           }) == {:error, {:negative_amount, :tip}}

    assert Checkout.apply(
             state,
             trusted("pickup"),
             Map.merge(cmd, %{fulfillment: :delivery, delivery: nil})
           ) == {:error, :delivery_required}

    assert map_size(state.orders) == 0
    assert state.carts["pickup"].status == :active
  end

  defp encode(%Money{} = value) do
    {currency, minor, _, _} = Money.to_integer_exp(value)
    %{"currency" => Atom.to_string(currency), "minor" => minor}
  end

  defp encode(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {Atom.to_string(k), encode(v)} end)

  defp encode(value) when is_list(value), do: Enum.map(value, &encode/1)
  defp encode(value) when is_atom(value), do: Atom.to_string(value)
  defp encode(value), do: value
end
