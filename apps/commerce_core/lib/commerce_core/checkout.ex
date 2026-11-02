defmodule CommerceCore.Checkout do
  @moduledoc """
  Pure checkout candidate projection: immutable priced lines, one order per cart,
  channel-scoped idempotency within one owner, and one delivery request for delivery.

  Home-bound candidates use `%{home_id: ..., merchant: ...}` in `new/2`;
  their cart snapshots and host grants must carry that exact ownership pair.
  Merchant-string constructors remain unscoped compatibility candidates.

  The host supplies a trusted cart snapshot and order index in `new/2`, and a
  verified per-cart checkout grant in `apply/3`. It must serialize admission and
  persist the cart completion, order and delivery outbox atomically. This module
  does not provide database concurrency, tracking secrets, transport execution,
  participant financial consent, or an authenticated financial receipt.

  Every new candidate has `financial_status: :unconfirmed`. Checkout, lifecycle
  completion and Tax.reverse/4 never imply settlement. Only a confirmed canonical
  TigerBeetle operation via the Hawala gateway can support financial acceptance;
  this reducer has no financial-acceptance operation.
  """

  alias CommerceCore.{Ownership, Pricing}

  def new(%{home_id: home, merchant: merchant} = owner, carts) when is_map(carts) do
    if Ownership.valid?(owner) and
         Enum.all?(carts, fn {id, cart} ->
           Ownership.id?(id) and Ownership.check(owner, cart) == :ok and
             Ownership.id?(Map.get(cart, :principal))
         end),
       do: {:ok, %{home_id: home, merchant: merchant, carts: carts, orders: %{}}},
       else: {:error, :invalid_checkout_projection}
  end

  def new(merchant, carts) when is_binary(merchant) and byte_size(merchant) > 0 and is_map(carts),
    do: {:ok, %{merchant: merchant, carts: carts, orders: %{}}}

  def new(_, _), do: {:error, :invalid_checkout_projection}

  @doc "Authorize before inspecting cart existence, status, prices or idempotency history."
  def apply(state, trusted, command) do
    with true <- authorized?(trusted, command),
         :ok <- scope(state, trusted) do
      checkout(state, trusted, command)
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc "Read a home-bound cart only with a current, exact per-cart host grant."
  def fetch_cart(%{home_id: _} = state, trusted, id) do
    with :ok <- read_grant(state, trusted, :cart_read, id),
         cart when is_map(cart) <- Map.get(state.carts, id),
         :ok <- Ownership.check(state, cart),
         true <- cart.principal == trusted.principal do
      {:ok, cart}
    else
      _ -> {:error, :forbidden}
    end
  end

  def fetch_cart(_, _, _), do: {:error, :forbidden}

  defp read_grant(state, trusted, operation, id) do
    with %{granted: true, operation: ^operation, cart_id: ^id, principal: p} <- trusted,
         true <- Ownership.id?(p),
         :ok <- scope(state, trusted),
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  defp scope(%{home_id: _} = state, trusted), do: Ownership.check(state, trusted)

  defp scope(%{merchant: merchant}, %{merchant: merchant} = trusted) do
    if Map.has_key?(trusted, :home_id), do: {:error, :forbidden}, else: :ok
  end

  defp scope(_, _), do: {:error, :forbidden}

  defp owned?(%{home_id: _} = state, record), do: Ownership.check(state, record) == :ok
  defp owned?(_, _), do: true

  defp authorized?(
         %{granted: true, operation: :checkout, principal: p, merchant: m, cart_id: cart},
         %{cart_id: cart}
       ) do
    is_binary(p) and byte_size(p) > 0 and is_binary(m) and byte_size(m) > 0 and
      is_binary(cart) and byte_size(cart) > 0
  end

  defp authorized?(_, _), do: false

  defp checkout(state, trusted, %{channel: channel, idempotency_key: key} = cmd)
       when channel in [:web, :telegram, :whatsapp, :phone, :aggregator, :pos] and
              is_binary(key) and byte_size(key) > 0 do
    cart = Map.get(state.carts, cmd.cart_id)

    # Ownership is checked before disclosing either an order or a key collision.
    if cart != nil and
         (not owned?(state, cart) or Map.get(cart, :principal) != trusted.principal) do
      {:error, :forbidden}
    else
      case Map.get(state.orders, {channel, key}) do
        nil ->
          place(state, cart, trusted, cmd)

        prior ->
          cond do
            not owned?(state, prior) or Map.get(prior, :principal) != trusted.principal ->
              {:error, :forbidden}

            prior.cart_id == cmd.cart_id ->
              {:ok, state, prior, :duplicate}

            true ->
              {:error, :idempotency_conflict}
          end
      end
    end
  end

  defp checkout(_, _, _), do: {:error, :invalid_checkout_command}

  defp place(_, nil, _, _), do: {:error, :unknown_cart}

  defp place(state, cart, trusted, %{adjustments: adjustments} = cmd) do
    with :ok <- fulfillment(cmd),
         :ok <- active(cart),
         :ok <- adjustments(adjustments),
         {:ok, priced} <- Pricing.price(cart.currency, cart.lines, cmd.adjustments) do
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
        adjustments: cmd.adjustments,
        delivery_request: if(cmd.fulfillment == :delivery, do: :required, else: nil),
        financial_status: :unconfirmed
      }

      order = Ownership.stamp(state, order)

      updated = %{
        state
        | carts: Map.put(state.carts, cmd.cart_id, %{cart | status: :completed}),
          orders: Map.put(state.orders, {cmd.channel, cmd.idempotency_key}, order)
      }

      {:ok, updated, order, :accepted}
    end
  end

  defp place(_, _, _, _), do: {:error, :invalid_checkout_command}

  defp adjustments(%{
         discount_total: %Money{},
         tax_total: %Money{},
         delivery_fee: %Money{},
         tip: %Money{}
       }),
       do: :ok

  defp adjustments(_), do: {:error, :invalid_adjustments}

  defp fulfillment(%{fulfillment: :delivery, delivery: details}) when is_map(details), do: :ok
  defp fulfillment(%{fulfillment: :delivery}), do: {:error, :delivery_required}
  defp fulfillment(%{fulfillment: f}) when f in [:pickup, :dine_in], do: :ok
  defp fulfillment(_), do: {:error, :invalid_fulfillment}

  defp active(%{status: :active, lines: [_ | _]}), do: :ok
  defp active(%{status: :active}), do: {:error, :empty_cart}
  defp active(_), do: {:error, :inactive_cart}
end
