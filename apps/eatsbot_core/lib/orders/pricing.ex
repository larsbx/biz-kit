defmodule EatsbotCore.Orders.Pricing do
  @moduledoc """
  Compatibility boundary for Eatsbot's I₂ pricing contract.

  The pricing algorithm is owned by `CommerceCore.Pricing` so other domain
  applications can reuse it. Existing Eatsbot callers retain the same
  `price/3` API, money semantics, and error terms. Kitchen and fulfillment
  rules remain in Eatsbot.
  """

  @type line :: %{unit_price: Money.t(), quantity: pos_integer(), discount: Money.t()}
  @type adjustments :: %{
          discount_total: Money.t(),
          tax_total: Money.t(),
          delivery_fee: Money.t(),
          tip: Money.t()
        }
  @type priced :: %{
          lines: [map()],
          subtotal: Money.t(),
          total: Money.t()
        }
  @type error ::
          :no_lines
          | :negative_total
          | {:invalid_quantity, non_neg_integer()}
          | {:currency_mismatch, atom()}
          | {:negative_amount, atom() | {non_neg_integer(), atom()}}
          | {:discount_exceeds_line, non_neg_integer()}

  @spec price(atom(), [line()], adjustments()) :: {:ok, priced()} | {:error, error()}
  defdelegate price(currency, lines, adjustments), to: CommerceCore.Pricing
end
