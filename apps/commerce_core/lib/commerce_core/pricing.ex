defmodule CommerceCore.Pricing do
  @moduledoc """
  Pure multi-currency-safe commercial order totals, extracted from Eatsbot's I₂:

      line.subtotal = unit_price × quantity − discount
      subtotal      = Σ line.subtotal
      total         = subtotal − discount_total + tax_total + delivery_fee + tip  ≥ 0

  For well-formed inputs, each calculation returns a priced result or a documented
  rejection; currencies are never converted. Inputs must have the documented keys
  and Money values. This is arithmetic, not tax calculation, FX or payment execution.
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

  @adjustments ~w(discount_total tax_total delivery_fee tip)a
  @line_amounts ~w(unit_price discount)a

  @spec price(atom(), [line()], adjustments()) :: {:ok, priced()} | {:error, error()}
  def price(_currency, [], _adjustments), do: {:error, :no_lines}

  def price(currency, lines, adjustments) do
    indexed = Enum.with_index(lines)

    with :ok <- check_quantities(indexed),
         :ok <- check_currency(currency, amounts(indexed, adjustments)),
         :ok <- check_non_negative(amounts(indexed, adjustments)),
         {:ok, priced_lines} <- price_lines(indexed) do
      subtotal = sum(currency, Enum.map(priced_lines, & &1.subtotal))

      total =
        subtotal
        |> Money.sub!(adjustments.discount_total)
        |> Money.add!(adjustments.tax_total)
        |> Money.add!(adjustments.delivery_fee)
        |> Money.add!(adjustments.tip)

      if Money.negative?(total),
        do: {:error, :negative_total},
        else: {:ok, %{lines: priced_lines, subtotal: subtotal, total: total}}
    end
  end

  # Every amount with a label naming where it came from, line amounts first.
  defp amounts(indexed, adjustments),
    do:
      for({line, i} <- indexed, key <- @line_amounts, do: {{i, key}, Map.fetch!(line, key)}) ++
        for(key <- @adjustments, do: {key, Map.fetch!(adjustments, key)})

  defp check_quantities(indexed) do
    case Enum.find(indexed, fn {%{quantity: q}, _} -> not (is_integer(q) and q >= 1) end) do
      nil -> :ok
      {_line, i} -> {:error, {:invalid_quantity, i}}
    end
  end

  defp check_currency(currency, amounts) do
    case Enum.find(amounts, fn {_label, money} -> money.currency != currency end) do
      nil -> :ok
      {_label, money} -> {:error, {:currency_mismatch, money.currency}}
    end
  end

  defp check_non_negative(amounts) do
    case Enum.find(amounts, fn {_label, money} -> Money.negative?(money) end) do
      nil -> :ok
      {label, _money} -> {:error, {:negative_amount, label}}
    end
  end

  defp price_lines(indexed) do
    Enum.reduce_while(indexed, {:ok, []}, fn {line, i}, {:ok, acc} ->
      subtotal = line.unit_price |> Money.mult!(line.quantity) |> Money.sub!(line.discount)

      if Money.negative?(subtotal),
        do: {:halt, {:error, {:discount_exceeds_line, i}}},
        else: {:cont, {:ok, [Map.put(line, :subtotal, subtotal) | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp sum(currency, amounts), do: Enum.reduce(amounts, Money.zero(currency), &Money.add!(&2, &1))
end
