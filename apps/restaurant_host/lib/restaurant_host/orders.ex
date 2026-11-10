defmodule RestaurantHost.Orders do
  @moduledoc """
  Orders as the host serves them, cash only: the storefront prices a basket
  (`CommerceCore.Catalog`, `Tax`, `Pricing`), signs `RestaurantOrderPlacedV1`
  with the storefront device and submits it to the Log; a paired board signs
  `RestaurantOrderStepV1`, and for a delivery order requests a driver
  (`RestaurantTransportRequestedV1`) or withdraws the request
  (`RestaurantTransportCancelRequestedV1`). The Log admits or refuses
  (`RestaurantCore.Admission`); the host never decides on its own and keeps no
  order state.

  Only Dispatch signs a transport step (`RestaurantTransportStepV1`) with a key
  the host never holds; no function here builds one.

  No financial operation exists here: payment is cash at pickup or on delivery,
  and money is Hawala's. The signed snapshot records the amounts in minor units.
  """

  alias CommerceCore.{Catalog, Pricing, Tax}
  alias CoopSubstrate.{Log, ULID}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.Admission
  alias RestaurantHost.Restaurant

  @doc "The menu: each item with its price."
  def menu(%Restaurant{} = r) do
    for %{id: id, name: name} <- r.menu do
      {:ok, quote} = Catalog.quote(r.catalog, r.merchant, id, nil, r.currency)
      %{id: id, name: name, price: quote.unit_price}
    end
  end

  @doc """
  Price a basket, `%{item_id => quantity}`: lines, subtotal, tax and total. A
  delivery basket adds the restaurant's fee as an itemized delivery charge,
  taxed only where the jurisdiction taxes it.
  """
  def price(%Restaurant{} = r, basket, fulfillment \\ :pickup) when is_map(basket) do
    names = Map.new(r.menu, &{&1.id, &1.name})
    zero = Money.zero(r.currency)

    with {:ok, fee} <- fee(r, fulfillment, zero),
         {:ok, lines} <- lines(r, basket, names),
         bases = Enum.map(lines, &Money.mult!(&1.unit_price, &1.quantity)),
         {:ok, tax} <- Tax.flat(r.currency, r.tax, bases, fee),
         adjustments = %{
           discount_total: zero,
           tax_total: tax.total,
           delivery_fee: fee,
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

  defp fee(_r, :pickup, zero), do: {:ok, zero}
  defp fee(%Restaurant{delivery: %{fee: fee}}, :delivery, _), do: {:ok, fee}
  defp fee(_r, :delivery, _), do: {:error, :delivery_unavailable}

  @doc "Whether delivery is offered: a delivery section and a Dispatch transport grant on the ledger."
  def delivery?(%Restaurant{delivery: nil}), do: false

  def delivery?(%Restaurant{} = r),
    do: Admission.transport?(Log.gate().restaurant, r.chapter, r.merchant)

  defp lines(r, basket, names) do
    basket
    |> Enum.filter(fn {_, qty} -> qty > 0 end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {id, qty}, {:ok, acc} ->
      case Catalog.quote(r.catalog, r.merchant, id, nil, r.currency) do
        {:ok, q} when is_integer(qty) ->
          line = %{
            item_id: id,
            name: names[id],
            unit_price: q.unit_price,
            quantity: qty,
            discount: Money.zero(r.currency)
          }

          {:cont, {:ok, acc ++ [line]}}

        _ ->
          {:halt, {:error, :unknown_item}}
      end
    end)
  end

  @doc """
  Place a pickup order, or, given `%{address, notes}`, a delivery order. `key`
  identifies this checkout attempt: submitting it again returns the same order
  rather than a second one.
  """
  def place(%Restaurant{} = r, basket, pickup_name, key, delivery \\ nil) do
    fulfillment = if delivery, do: :delivery, else: :pickup

    with :ok <- if(delivery && not delivery?(r), do: {:error, :delivery_unavailable}, else: :ok),
         {:ok, details} <- delivery_details(delivery),
         {:ok, priced} <- price(r, basket, fulfillment) do
      payload =
        %{
          "merchant_id" => r.merchant,
          "order_id" => ULID.generate(),
          "cart_id" => key,
          "principal_id" => "guest:" <> key,
          "channel" => "web",
          "idempotency_key" => key,
          "fulfillment" => Atom.to_string(fulfillment),
          "pickup_name" => pickup_name,
          "currency" => Atom.to_string(r.currency),
          "lines" => Enum.map(priced.lines, &signed_line/1),
          "subtotal_minor" => minor(priced.subtotal),
          "total_minor" => minor(priced.total),
          "adjustments" =>
            Map.new(priced.adjustments, fn {k, v} -> {Atom.to_string(k), minor(v)} end)
        }
        |> then(&if(details, do: Map.put(&1, "delivery", details), else: &1))

      case submit(r, r.storefront, "RestaurantOrderPlacedV1", payload) do
        :ok -> {:ok, payload["order_id"]}
        {:error, {:duplicate_checkout, id}} -> {:ok, id}
        error -> error
      end
    end
  end

  @doc "Take an order step from a paired board, at the order's current version."
  def step(%Restaurant{} = r, board_id, order_id, action, version, reason \\ nil) do
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

      submit(r, board, "RestaurantOrderStepV1", payload)
    end
  end

  @doc "Request a driver for a ready delivery order from a paired board, at the order's version."
  def request_transport(%Restaurant{} = r, board_id, order_id, version) do
    with {:ok, board} <- Map.fetch(r.boards, board_id) |> or_forbidden() do
      submit(r, board, "RestaurantTransportRequestedV1", %{
        "merchant_id" => r.merchant,
        "order_id" => order_id,
        "request_id" => ULID.generate(),
        "expected_version" => version
      })
    end
  end

  @doc """
  Cancel from a paired board. While a driver request is live, withdraw it
  first: before Dispatch accepts, the order then cancels at once (`:ok`);
  after, the withdrawal waits for Dispatch (`{:ok, :pending}`). Once Dispatch
  confirms it or reports a failure before pickup, the board's Cancel finishes
  the cancellation. Anything else is the ledger's answer to the cancel step.
  """
  def cancel(%Restaurant{} = r, board_id, order_id, reason) do
    with {:ok, board} <- Map.fetch(r.boards, board_id) |> or_forbidden(),
         %{} = order <- get(r, order_id) || {:error, :forbidden},
         :ok <- withdraw(r, board, order, reason),
         %{} = order <- get(r, order_id) do
      if match?(%{view: :cancel_pending}, order.handoff),
        do: {:ok, :pending},
        else: step(r, board_id, order_id, :cancel, order.version, reason)
    end
  end

  defp withdraw(r, board, %{handoff_actions: actions, handoff: handoff} = order, reason) do
    if :withdraw_transport in actions,
      do:
        submit(r, board, "RestaurantTransportCancelRequestedV1", %{
          "merchant_id" => r.merchant,
          "order_id" => order.id,
          "request_id" => handoff.request_id,
          "command_id" => ULID.generate(),
          "expected_version" => handoff.version,
          "reason" => reason
        }),
      else: :ok
  end

  defp or_forbidden({:ok, board}), do: {:ok, board}
  defp or_forbidden(:error), do: {:error, :forbidden}

  @doc "The restaurant's orders as the Log has admitted them, oldest first."
  def list(%Restaurant{} = r), do: Admission.orders(Log.gate().restaurant, r.chapter, r.merchant)

  def get(%Restaurant{} = r, id), do: Enum.find(list(r), &(&1.id == id))

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

  # The guest's address (trimmed, 1..200 characters) and optional notes (≤ 200).
  defp delivery_details(nil), do: {:ok, nil}

  defp delivery_details(%{} = d) do
    address = String.trim(Map.get(d, :address) || "")
    notes = String.trim(Map.get(d, :notes) || "")

    if address != "" and String.length(address) <= 200 and String.length(notes) <= 200,
      do:
        {:ok,
         if(notes == "",
           do: %{"address" => address},
           else: %{"address" => address, "notes" => notes}
         )},
      else: {:error, :invalid_address}
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
