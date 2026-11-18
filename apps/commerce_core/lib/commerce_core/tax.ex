defmodule CommerceCore.Tax do
  @moduledoc """
  Pure sales-tax arithmetic for an order, computed once at checkout and then
  copied onto the order like its prices. All arithmetic is exact, on integer
  minor units; currencies are never converted.

  A flat profile is one combined rate `r` (a `Decimal`, `0 ≤ r < 1`) and
  whether the delivery fee is taxed. With taxable bases `bᵢ` (line amounts,
  then the fee or 0) and `B = Σ bᵢ`:

      tax_total = ⌊B·r + ½⌋                        half-up, once per order
      shareᵢ    = ⌊bᵢ·r⌋ + [i among the largest remainders]
      I₇        tax_total = Σ line taxes + fee tax,  every share ≥ 0,
                |shareᵢ − bᵢ·r| < 1

  Tips are not an input, so they are never taxed. A refund reverses tax in
  proportion to the amount refunded, cumulatively, so the refunds of a whole
  order reverse exactly its tax. Jurisdiction lookup, marketplace remittance
  and filing are the host's: this module only does the arithmetic.
  """

  @type profile :: %{rate: Decimal.t(), fee_taxable?: boolean()}
  @type taxed :: %{lines: [Money.t()], fee: Money.t(), total: Money.t()}
  @type error ::
          :no_lines
          | :invalid_rate
          | :refund_exceeds_total
          | {:currency_mismatch, atom()}
          | {:negative_amount, {:line, non_neg_integer()} | atom()}

  @doc "Taxes `lines` (and the delivery fee, where the profile says so) at a flat rate."
  @spec flat(atom(), profile(), [Money.t()], Money.t()) :: {:ok, taxed()} | {:error, error()}
  def flat(_currency, _profile, [], _delivery_fee), do: {:error, :no_lines}

  def flat(currency, %{rate: rate, fee_taxable?: fee_taxable?}, lines, delivery_fee) do
    labelled =
      Enum.with_index(lines, fn line, i -> {{:line, i}, line} end) ++
        [{:delivery_fee, delivery_fee}]

    with {:ok, {num, den}} <- fraction(rate),
         {:ok, [_ | _] = amounts} <- minor_units(currency, labelled) do
      {line_bases, [fee]} = Enum.split(amounts, -1)
      bases = line_bases ++ [if(fee_taxable?, do: fee, else: 0)]
      total = div(2 * Enum.sum(bases) * num + den, 2 * den)
      {line_taxes, [fee_tax]} = bases |> allocate(total, num, den) |> Enum.split(-1)

      {:ok,
       %{
         lines: Enum.map(line_taxes, &Money.from_integer(&1, currency)),
         fee: Money.from_integer(fee_tax, currency),
         total: Money.from_integer(total, currency)
       }}
    end
  end

  @doc """
  The tax a refund reverses: the order's tax in proportion to what has been
  refunded, after this refund less before it, each rounded half-up.
  """
  @spec reverse(Money.t(), Money.t(), Money.t(), Money.t()) ::
          {:ok, Money.t()} | {:error, error()}
  def reverse(tax_total, order_total, refunded_before, refund) do
    currency = tax_total.currency

    labelled = [
      tax_total: tax_total,
      order_total: order_total,
      refunded_before: refunded_before,
      refund: refund
    ]

    with {:ok, [tax, total, before, amount]} <- minor_units(currency, labelled) do
      cond do
        before + amount > total ->
          {:error, :refund_exceeds_total}

        # Only a free order can have a zero total, and it carries no tax.
        total == 0 ->
          {:ok, Money.zero(currency)}

        true ->
          reversed = fn refunded -> div(2 * tax * refunded + total, 2 * total) end
          {:ok, Money.from_integer(reversed.(before + amount) - reversed.(before), currency)}
      end
    end
  end

  # ⌊bᵢ·r⌋ each, then one more minor unit to the largest remainders until the
  # shares reach the order's rounded total (ties go to the earlier share).
  defp allocate(bases, total, num, den) do
    floors = Enum.map(bases, &div(&1 * num, den))
    extra = total - Enum.sum(floors)

    winners =
      bases
      |> Enum.with_index()
      |> Enum.sort_by(fn {b, i} -> {-rem(b * num, den), i} end)
      |> Enum.take(extra)
      |> MapSet.new(fn {_b, i} -> i end)

    floors
    |> Enum.with_index()
    |> Enum.map(fn {floor, i} -> if i in winners, do: floor + 1, else: floor end)
  end

  defp fraction(%Decimal{sign: 1, coef: coef, exp: exp}) when is_integer(coef) do
    {num, den} = if exp >= 0, do: {coef * 10 ** exp, 1}, else: {coef, 10 ** -exp}
    if num < den, do: {:ok, {num, den}}, else: {:error, :invalid_rate}
  end

  defp fraction(_rate), do: {:error, :invalid_rate}

  defp minor_units(currency, labelled) do
    Enum.reduce_while(labelled, {:ok, []}, fn {label, money}, {:ok, acc} ->
      cond do
        money.currency != currency -> {:halt, {:error, {:currency_mismatch, money.currency}}}
        Money.negative?(money) -> {:halt, {:error, {:negative_amount, label}}}
        true -> {:cont, {:ok, [money |> Money.to_integer_exp() |> elem(1) | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
