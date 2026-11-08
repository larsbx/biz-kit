defmodule CommerceCore.Discounts do
  @moduledoc """
  Pure discount rules for one order line, in exact integer minor units.

  With unit price `u`, quantity `q` and line base `B = u·q`, a rule's discount:

      percent_off  r ∈ (0, 1]       ⌊B·r + ½⌋                  half-up, like Tax
      unit_price   p                 max(0, u − p) · q          lowers, never raises
      buy_x_pay_y  x > y ≥ 1         ⌊q / x⌋ · (x − y) · u
      x_for_amount x ≥ 2, a > 0      ⌊q / x⌋ · max(0, x·u − a)

  A rule applies when it is enabled, `q ≥ min_quantity`, the weekday and hour
  match (`hours: {from, to}` is inclusive and wraps past midnight when
  `from > to`), and any amount it names is in the line's currency. Rules do
  not stack: `best/3` takes the largest discount, ties to the earlier rule, so
  `0 ≤ discount ≤ B` and `Pricing.price/3` accepts the line.

  The clock is an input (`%{weekday: 1..7, hour: 0..23}`, ISO weekday, in the
  merchant's local time); the host reads it. Differences from Eatsbot's
  `DiscountsCalculation`, which is not migrated (decommission D1): `:fixed`
  there set the unit price, here it is named `unit_price`; bundles are not
  divided back into per-unit prices, so nothing rounds but `percent_off`; the
  clock is not read inside the rule, and an overnight window is not a
  descending range; an amount in another currency never applies.
  """

  @type at :: %{weekday: 1..7, hour: 0..23}
  @type line :: %{unit_price: Money.t(), quantity: pos_integer()}
  @type rule :: %{
          required(:id) => String.t(),
          required(:method) => atom(),
          optional(atom()) => term()
        }

  @conditions %{enabled: true, weekdays: :any, hours: :any, min_quantity: 1}

  @doc "Validate a rule and fill in its default conditions."
  @spec normalize(map()) :: {:ok, rule()} | {:error, :invalid_discount}
  def normalize(%{id: id, method: method} = attrs)
      when is_binary(id) and byte_size(id) in 1..128 do
    rule = Map.merge(@conditions, attrs)

    if valid_method?(method, rule) and valid_conditions?(rule),
      do: {:ok, Map.take(rule, [:id, :method | Map.keys(@conditions)] ++ fields(method))},
      else: {:error, :invalid_discount}
  end

  def normalize(_), do: {:error, :invalid_discount}

  @doc "The single best applicable rule's discount for a line, and that rule's id (or nil)."
  @spec best([rule()], line(), at()) :: %{discount: Money.t(), rule: String.t() | nil}
  def best(rules, %{unit_price: %Money{currency: currency} = unit, quantity: q}, at) do
    u = minor(unit)

    {amount, id} =
      rules
      |> Enum.filter(&applies?(&1, currency, q, at))
      |> Enum.reduce({0, nil}, fn rule, {top, _} = acc ->
        d = discount(rule, u, q)
        if d > top, do: {d, rule.id}, else: acc
      end)

    %{discount: Money.from_integer(amount, currency), rule: id}
  end

  defp fields(:percent_off), do: [:rate]
  defp fields(:unit_price), do: [:price]
  defp fields(:buy_x_pay_y), do: [:x, :y]
  defp fields(:x_for_amount), do: [:x, :amount]

  defp valid_method?(:percent_off, %{rate: %Decimal{} = r}),
    do: Decimal.gt?(r, 0) and not Decimal.gt?(r, 1)

  defp valid_method?(:unit_price, %{price: %Money{} = p}), do: not Money.negative?(p)

  defp valid_method?(:buy_x_pay_y, %{x: x, y: y}) when is_integer(x) and is_integer(y),
    do: 1 <= y and y < x

  defp valid_method?(:x_for_amount, %{x: x, amount: %Money{} = a}) when is_integer(x),
    do: x >= 2 and Money.positive?(a)

  defp valid_method?(_, _), do: false

  defp valid_conditions?(%{enabled: on, weekdays: days, hours: hours, min_quantity: n}) do
    is_boolean(on) and is_integer(n) and n >= 1 and
      (days == :any or (is_list(days) and days != [] and Enum.all?(days, &(&1 in 1..7)))) and
      (hours == :any or match?({f, t} when f in 0..23 and t in 0..23, hours))
  end

  defp applies?(rule, currency, q, %{weekday: day, hour: hour}) do
    rule.enabled and q >= rule.min_quantity and (rule.weekdays == :any or day in rule.weekdays) and
      in_hours?(rule.hours, hour) and same_currency?(rule, currency)
  end

  defp in_hours?(:any, _), do: true
  defp in_hours?({from, to}, h) when from <= to, do: from <= h and h <= to
  defp in_hours?({from, to}, h), do: h >= from or h <= to

  defp same_currency?(%{price: %Money{currency: c}}, currency), do: c == currency
  defp same_currency?(%{amount: %Money{currency: c}}, currency), do: c == currency
  defp same_currency?(_, _), do: true

  defp discount(%{method: :percent_off, rate: r}, u, q) do
    {num, den} = fraction(r)
    div(2 * u * q * num + den, 2 * den)
  end

  defp discount(%{method: :unit_price, price: p}, u, q), do: max(0, u - minor(p)) * q
  defp discount(%{method: :buy_x_pay_y, x: x, y: y}, u, q), do: div(q, x) * (x - y) * u

  defp discount(%{method: :x_for_amount, x: x, amount: a}, u, q),
    do: div(q, x) * max(0, x * u - minor(a))

  defp fraction(%Decimal{coef: coef, exp: exp}) when exp >= 0, do: {coef * 10 ** exp, 1}
  defp fraction(%Decimal{coef: coef, exp: exp}), do: {coef, 10 ** -exp}

  defp minor(money), do: money |> Money.to_integer_exp() |> elem(1)
end
