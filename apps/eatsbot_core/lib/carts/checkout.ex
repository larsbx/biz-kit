defmodule EatsbotCore.Carts.Checkout do
  @moduledoc """
  Turns an active cart into a placed `EatsbotCore.Orders.Order`, in one transaction.

  - the cart is locked before anything is read, so concurrent checkouts of one cart
    serialize, and a repeated `(channel, idempotency_key)` returns the existing order
    even when the copies race (I₅)
  - prices are copied from the variants in the cart's currency (I₁, I₂)
  - a delivery order also gets its `Delivery` (I₄)

  Returns `%{order_id, tracking_key, delivery_key}`; `delivery_key` is nil unless
  the order is for delivery.
  """
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias EatsbotCore.Carts.Cart
  alias EatsbotCore.Deliveries.Delivery
  alias EatsbotCore.Orders.{ActorIn, Order}

  @impl true
  def run(%{arguments: args}, _opts, _context) do
    channel = Map.get(args, :channel, :web)

    # The cart lock comes first: copies of one checkout queue on it, so each copy's
    # key lookup sees the order an earlier copy committed (look-then-lock races).
    with {:ok, cart} <- lock_cart(args.cart_id) do
      case existing_order(channel, args.idempotency_key) do
        %Order{cart_id: cart_id} = order when cart_id == cart.id -> {:ok, result(order)}
        %Order{} -> {:error, invalid(:idempotency_key, "was already used for another cart")}
        nil -> place(cart, args, channel)
      end
    end
  end

  defp place(cart, args, channel) do
    with :ok <- require_delivery_details(args),
         :ok <- require_active(cart),
         {:ok, order} <- create_order(cart, args, channel),
         {:ok, _cart} <- Ash.update(cart, %{status: :completed}),
         {:ok, order} <- maybe_create_delivery(order, cart, args) do
      {:ok, result(order)}
    end
  end

  defp require_delivery_details(%{fulfillment: :delivery} = args) do
    if is_map(args[:delivery]),
      do: :ok,
      else: {:error, invalid(:delivery, "is required for a delivery order")}
  end

  defp require_delivery_details(_args), do: :ok

  defp require_active(%Cart{status: :active, cart_lines: [_ | _]}), do: :ok
  defp require_active(%Cart{status: :active}), do: {:error, invalid(:cart_id, "cart is empty")}
  defp require_active(%Cart{}), do: {:error, invalid(:cart_id, "cart is not active")}

  defp existing_order(channel, key) do
    Order
    |> Ash.Query.filter(channel == ^channel and idempotency_key == ^key)
    |> Ash.Query.load(:delivery)
    |> Ash.read_one!(actor: ActorIn.system())
  end

  defp lock_cart(cart_id) do
    Cart
    |> Ash.Query.filter(id == ^cart_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.load(cart_lines: [:subtotal, variant: [prices: [:currency]]])
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, invalid(:cart_id, "cart does not exist")}
      result -> result
    end
  end

  defp create_order(cart, args, channel) do
    Order.place(
      %{
        cart_id: cart.id,
        channel: channel,
        fulfillment: args.fulfillment,
        currency: cart.currency,
        contact: args.contact,
        scheduled_for: args[:scheduled_for],
        idempotency_key: args.idempotency_key,
        tip: args[:tip],
        delivery_fee: args[:delivery_fee],
        lines: Enum.map(cart.cart_lines, &line_snapshot(&1, cart.currency))
      },
      actor: ActorIn.system()
    )
  end

  # unit_price is the variant's list price in the cart's currency; whatever the
  # discount rules took off the line is kept as the line's discount.
  defp line_snapshot(line, currency) do
    %{money: unit_price} = Enum.find(line.variant.prices, &(&1.currency == currency))

    %{
      variant_id: line.variant_id,
      name: line.variant.name,
      quantity: line.quantity,
      notes: line.notes,
      unit_price: unit_price,
      discount: unit_price |> Money.mult!(line.quantity) |> Money.sub!(line.subtotal)
    }
  end

  defp maybe_create_delivery(%Order{fulfillment: :delivery} = order, cart, args) do
    args.delivery
    |> Map.merge(%{order_id: order.id, delivery_order: legacy_order_map(cart)})
    |> Delivery.for_order(actor: ActorIn.system())
    |> case do
      {:ok, delivery} -> {:ok, %{order | delivery: delivery}}
      error -> error
    end
  end

  defp maybe_create_delivery(order, _cart, _args), do: {:ok, %{order | delivery: nil}}

  # Kept until the Telegram chains read lines from the order (spec E0.1, migration).
  defp legacy_order_map(cart),
    do: %{
      cart_id: cart.id,
      cart_lines: Enum.map(cart.cart_lines, &%{quantity: &1.quantity, name: &1.variant.name})
    }

  defp result(order),
    do: %{
      order_id: order.id,
      tracking_key: order.tracking_key,
      delivery_key: order.delivery && order.delivery.public_auth_key
    }

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
end
