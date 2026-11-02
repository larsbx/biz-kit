defmodule OrderCore.Placement do
  @moduledoc """
  Money-free order placement: one order per cart, channel-scoped idempotency,
  cart ownership, the workflow's fulfillments, and exactly one delivery request
  for delivery. Authorization precedes every observation.

  The priced snapshot is opaque here: `apply/4` takes a pricing function, so
  `CommerceCore.Checkout` prices with Money while a signed-log admission records
  a device-signed snapshot in minor units. Money itself is Hawala's: no
  placement, lifecycle step or snapshot asserts payment or settlement, and every
  order is `financial_status: :unconfirmed`.

  The host supplies a trusted cart snapshot and order index in `new/3` and a
  verified per-cart grant in `apply/4`; it serializes admission and persists
  the result atomically.
  """

  @channels [:web, :telegram, :whatsapp, :phone, :aggregator, :pos]

  @doc "The channels an order may be placed through."
  def channels, do: @channels

  @doc """
  A projection for one merchant. The workflow (`OrderCore.Lifecycle.workflow/1`)
  names the fulfillments placement offers, so every placed order can start its
  lifecycle.
  """
  def new(%{fulfillments: [_ | _] = fulfillments}, merchant, carts)
      when is_binary(merchant) and byte_size(merchant) > 0 and is_map(carts),
      do: {:ok, %{merchant: merchant, fulfillments: fulfillments, carts: carts, orders: %{}}}

  def new(_, _, _), do: {:error, :invalid_checkout_projection}

  @doc """
  Authorize before inspecting cart existence, status, prices or idempotency
  history. `price.(cart, command)` returns the order's priced snapshot
  (`%{lines:, subtotal:, total:, adjustments:}`) or an error; it runs only for a
  new order on an owned, active cart with an offered fulfillment.
  """
  def apply(state, trusted, command, price) when is_function(price, 2) do
    with true <- authorized?(trusted, command),
         %{merchant: merchant} when merchant == trusted.merchant <- state do
      checkout(state, trusted, command, price)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorized?(
         %{granted: true, operation: :checkout, principal: p, merchant: m, cart_id: cart},
         %{cart_id: cart}
       ) do
    is_binary(p) and byte_size(p) > 0 and is_binary(m) and byte_size(m) > 0 and
      is_binary(cart) and byte_size(cart) > 0
  end

  defp authorized?(_, _), do: false

  defp checkout(state, trusted, %{channel: channel, idempotency_key: key} = cmd, price)
       when channel in @channels and
              is_binary(key) and byte_size(key) > 0 do
    cart = Map.get(state.carts, cmd.cart_id)

    # Ownership is checked before disclosing either an order or a key collision.
    if cart != nil and Map.get(cart, :principal) != trusted.principal do
      {:error, :forbidden}
    else
      case Map.get(state.orders, {channel, key}) do
        %{principal: principal} when principal != trusted.principal ->
          {:error, :forbidden}

        %{cart_id: cart_id} = prior when cart_id == cmd.cart_id ->
          {:ok, state, prior, :duplicate}

        %{} ->
          {:error, :idempotency_conflict}

        nil ->
          place(state, cart, trusted, cmd, price)
      end
    end
  end

  defp checkout(_, _, _, _), do: {:error, :invalid_checkout_command}

  defp place(_, nil, _, _, _), do: {:error, :unknown_cart}

  defp place(state, cart, trusted, %{cart_id: _} = cmd, price) do
    with :ok <- fulfillment(state.fulfillments, cmd),
         :ok <- active(cart),
         {:ok, priced} <- price.(cart, cmd) do
      order = %{
        merchant: state.merchant,
        principal: trusted.principal,
        cart_id: cmd.cart_id,
        channel: cmd.channel,
        idempotency_key: cmd.idempotency_key,
        fulfillment: cmd.fulfillment,
        currency: cart.currency,
        state: :placed,
        state_changes: [],
        lines: priced.lines,
        subtotal: priced.subtotal,
        total: priced.total,
        adjustments: priced.adjustments,
        delivery_request: if(cmd.fulfillment == :delivery, do: :required, else: nil),
        financial_status: :unconfirmed
      }

      updated = %{
        state
        | carts: Map.put(state.carts, cmd.cart_id, %{cart | status: :completed}),
          orders: Map.put(state.orders, {cmd.channel, cmd.idempotency_key}, order)
      }

      {:ok, updated, order, :accepted}
    end
  end

  defp place(_, _, _, _, _), do: {:error, :invalid_checkout_command}

  defp fulfillment(offered, %{fulfillment: f} = cmd) do
    cond do
      f not in offered -> {:error, :invalid_fulfillment}
      f == :delivery and not is_map(Map.get(cmd, :delivery)) -> {:error, :delivery_required}
      true -> :ok
    end
  end

  defp fulfillment(_, _), do: {:error, :invalid_fulfillment}

  defp active(%{status: :active, lines: [_ | _]}), do: :ok
  defp active(%{status: :active}), do: {:error, :empty_cart}
  defp active(_), do: {:error, :inactive_cart}
end
