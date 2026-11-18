defmodule CommerceCore.Checkout do
  @moduledoc """
  Checkout: `OrderCore.Placement` priced by `CommerceCore.Pricing`. Immutable
  priced lines, one order per cart, channel-scoped idempotency, and exactly one
  delivery request for delivery.

  The host supplies a trusted cart snapshot and order index in `new/3`, and a
  verified per-cart checkout grant in `apply/3`. It must serialize admission and
  persist the cart completion, order and delivery outbox atomically. This module
  does not provide database concurrency, tracking secrets, transport execution,
  participant financial consent, or an authenticated financial receipt.

  Every new candidate has `financial_status: :unconfirmed`. Checkout, lifecycle
  completion and Tax.reverse/4 never imply settlement. Money is accepted only by
  Hawala (a confirmed TigerBeetle operation through its gateway); this reducer
  has no financial-acceptance operation.
  """

  alias CommerceCore.Pricing
  alias OrderCore.Placement

  defdelegate channels, to: Placement
  defdelegate new(workflow, merchant, carts), to: Placement

  @doc "Authorize before inspecting cart existence, status, prices or idempotency history."
  def apply(state, trusted, command), do: Placement.apply(state, trusted, command, &price/2)

  defp price(cart, %{adjustments: adjustments}) do
    with :ok <- adjustments(adjustments),
         {:ok, priced} <- Pricing.price(cart.currency, cart.lines, adjustments),
         do: {:ok, Map.put(priced, :adjustments, adjustments)}
  end

  defp price(_, _), do: {:error, :invalid_checkout_command}

  defp adjustments(%{
         discount_total: %Money{},
         tax_total: %Money{},
         delivery_fee: %Money{},
         tip: %Money{}
       }),
       do: :ok

  defp adjustments(_), do: {:error, :invalid_adjustments}
end
