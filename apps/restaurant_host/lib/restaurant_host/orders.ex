defmodule RestaurantHost.Orders do
  @moduledoc """
  Orders as the host serves them, cash only: the storefront prices a basket
  (`CommerceCore.Catalog`, `Tax`, `Pricing`), signs `RestaurantOrderPlacedV1`
  with the storefront device and submits it to the Log; a paired board signs
  `RestaurantOrderStepV1`. The Log admits or refuses (`RestaurantCore.Admission`);
  the host never decides on its own and keeps no order state.

  No financial operation exists here: payment is cash at handoff, and money is
  Hawala's. The signed snapshot records the amounts in minor units.
  """

  alias CommerceCore.{Catalog, Pricing, Tax}
  alias CoopSubstrate.{Log, ULID}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.Admission
  alias RestaurantHost.Restaurant

  @doc "The menu: each item with its price."
  def menu(%Restaurant{} = r) do
    for %{id: id, name: name} = item <- r.menu do
      {:ok, quote} = Catalog.quote(r.catalog, r.merchant, id, nil, r.currency)
      discount = item_discount(item, r.currency)
      %{id: id, name: name, price: Money.sub!(quote.unit_price, discount)}
    end
  end

  @doc "Price a basket, `%{item_id => quantity}`: lines, subtotal, tax and total."
  def price(%Restaurant{} = r, basket) when is_map(basket) do
    items = Map.new(r.menu, &{&1.id, &1})
    zero = Money.zero(r.currency)

    with {:ok, lines} <- lines(r, basket, items),
         bases = Enum.map(lines, &tax_base/1),
         {:ok, tax} <- Tax.flat(r.currency, r.tax, bases, zero),
         adjustments = %{
           discount_total: zero,
           tax_total: tax.total,
           delivery_fee: zero,
           tip: zero
         },
         {:ok, priced} <- Pricing.price(r.currency, lines, adjustments) do
      {:ok,
       %{
         lines: Enum.zip_with(lines, priced.lines, &Map.put(&1, :subtotal, &2.subtotal)),
         subtotal: priced.subtotal,
         tax: tax.total,
         total: priced.total,
         adjustments: adjustments
       }}
    end
  end

  # A published line discount is offered and funded by the seller at checkout.
  defp tax_base(line) do
    line.unit_price |> Money.mult!(line.quantity) |> Money.sub!(line.discount)
  end

  defp item_discount(item, currency),
    do: Money.from_integer(Map.get(item, :discount_minor, 0), currency)

  defp lines(r, basket, items) do
    basket
    |> Enum.filter(fn {_, qty} -> qty > 0 end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {id, qty}, {:ok, acc} ->
      case Catalog.quote(r.catalog, r.merchant, id, nil, r.currency) do
        {:ok, q} when is_integer(qty) ->
          item = Map.fetch!(items, id)

          line = %{
            item_id: id,
            name: item.name,
            unit_price: q.unit_price,
            quantity: qty,
            discount: item |> item_discount(r.currency) |> Money.mult!(qty)
          }

          {:cont, {:ok, acc ++ [line]}}

        _ ->
          {:halt, {:error, :unknown_item}}
      end
    end)
  end

  @doc """
  Place a pickup or configured delivery order. `key` identifies this checkout attempt: submitting it
  again returns the same order rather than a second one.
  """
  def place(
        %Restaurant{} = r,
        basket,
        pickup_name,
        key,
        principal \\ nil,
        fulfillment \\ "pickup"
      ) do
    with :ok <- offered(r, fulfillment),
         {:ok, priced} <- price(r, basket) do
      order_id = ULID.generate()

      payload = %{
        "merchant_id" => r.merchant,
        "order_id" => order_id,
        "cart_id" => key,
        "principal_id" => principal || "guest:" <> key,
        "menu_revision" => r.menu_revision,
        "channel" => "web",
        "idempotency_key" => key,
        "fulfillment" => fulfillment,
        "pickup_name" => pickup_name,
        "currency" => Atom.to_string(r.currency),
        "lines" => Enum.map(priced.lines, &signed_line/1),
        "subtotal_minor" => minor(priced.subtotal),
        "total_minor" => minor(priced.total),
        "adjustments" =>
          Map.new(priced.adjustments, fn {k, v} -> {Atom.to_string(k), minor(v)} end)
      }

      payload =
        if fulfillment == "delivery",
          do: Map.put(payload, "delivery", %{"request_id" => order_id}),
          else: payload

      case submit(r, r.storefront, "RestaurantOrderPlacedV1", payload) do
        :ok -> {:ok, payload["order_id"]}
        {:error, {:duplicate_checkout, id}} -> {:ok, id}
        error -> error
      end
    end
  end

  defp offered(_, "pickup"), do: :ok

  defp offered(r, "delivery") do
    if Restaurant.delivery_available?(r), do: :ok, else: {:error, :invalid_fulfillment}
  end

  defp offered(_, _), do: {:error, :invalid_fulfillment}

  @doc "Take an order step from a paired board, at the order's current version."
  def step(%Restaurant{} = r, board_id, order_id, action, version, reason \\ nil, staff \\ nil) do
    with {:ok, board} <- Map.fetch(r.boards, board_id) |> or_forbidden() do
      payload =
        %{
          "merchant_id" => r.merchant,
          "order_id" => order_id,
          "command_id" => ULID.generate(),
          "expected_version" => version,
          "action" => Atom.to_string(action)
        }
        |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
        |> then(&if(staff, do: Map.put(&1, "staff_principal", staff), else: &1))

      submit(r, board, "RestaurantOrderStepV1", payload)
    end
  end

  defp or_forbidden({:ok, board}), do: {:ok, board}
  defp or_forbidden(:error), do: {:error, :forbidden}

  @doc "The restaurant's orders as the Log has admitted them, oldest first."
  def list(%Restaurant{} = r), do: Admission.orders(Log.gate().restaurant, r.chapter, r.merchant)

  def get(%Restaurant{} = r, id), do: Enum.find(list(r), &(&1.id == id))

  def for_principal(%Restaurant{} = r, principal) when is_binary(principal),
    do: Enum.filter(list(r), &(&1.principal == principal))

  @doc "Receive `{:coop_ledger, envelopes}` for every admitted batch."
  def subscribe, do: :pg.join(CoopSubstrate.Feed, :ledger, self())

  defp submit(r, device, type, payload) do
    {:ok, env} =
      Envelope.new(%{
        event_id: ULID.generate(),
        chapter_id: r.chapter,
        type: type,
        payload: payload,
        signers: [device.signer],
        auth_ref: nil,
        timestamp_ms: System.system_time(:millisecond)
      })

    {:ok, signed} = Envelope.sign(env, device.signer.key_id, device.seed)

    case Log.append(signed) do
      {:ok, _} -> :ok
      {:error, {:reject, 0, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signed_line(l),
    do: %{
      "item_id" => l.item_id,
      "name" => l.name,
      "unit_minor" => minor(l.unit_price),
      "quantity" => l.quantity,
      "discount_minor" => minor(l.discount)
    }

  defp minor(money), do: money |> Money.to_integer_exp() |> elem(1)
end
