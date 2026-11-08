defmodule CommerceCore.DiscountsTest do
  @moduledoc """
  Discount rules (Eatsbot decommission D5): a line gets the single best
  applicable rule's discount, in exact minor units, never more than the line.
  The clock is an input, so the rules stay pure.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.{Discounts, Pricing}

  defp m(minor, currency \\ :USD), do: Money.from_integer(minor, currency)
  defp minor(money), do: money |> Money.to_integer_exp() |> elem(1)

  @noon_tue %{weekday: 2, hour: 12}

  defp rule!(attrs) do
    {:ok, rule} = Discounts.normalize(Map.merge(%{id: "r"}, attrs))
    rule
  end

  defp best(rules, unit, qty, at \\ @noon_tue),
    do: Discounts.best(rules, %{unit_price: m(unit), quantity: qty}, at)

  describe "normalize/1" do
    test "accepts each method and defaults its conditions" do
      for attrs <- [
            %{method: :percent_off, rate: Decimal.new("0.15")},
            %{method: :unit_price, price: m(900)},
            %{method: :buy_x_pay_y, x: 3, y: 2},
            %{method: :x_for_amount, x: 2, amount: m(2000)}
          ] do
        assert {:ok, rule} = Discounts.normalize(Map.put(attrs, :id, "r"))
        assert %{enabled: true, weekdays: :any, hours: :any, min_quantity: 1} = rule
      end
    end

    test "refuses malformed rules" do
      for attrs <- [
            %{method: :percent_off, rate: Decimal.new("0")},
            %{method: :percent_off, rate: Decimal.new("1.01")},
            %{method: :percent_off, rate: 0.5},
            %{method: :unit_price, price: m(-1)},
            %{method: :buy_x_pay_y, x: 2, y: 2},
            %{method: :buy_x_pay_y, x: 3, y: 0},
            %{method: :x_for_amount, x: 1, amount: m(100)},
            %{method: :x_for_amount, x: 2, amount: m(0)},
            %{method: :percent_off, rate: Decimal.new("0.1"), weekdays: [0]},
            %{method: :percent_off, rate: Decimal.new("0.1"), weekdays: []},
            %{method: :percent_off, rate: Decimal.new("0.1"), hours: {9, 24}},
            %{method: :percent_off, rate: Decimal.new("0.1"), min_quantity: 0},
            %{method: :fixed, discount: 5}
          ] do
        assert {:error, :invalid_discount} = Discounts.normalize(Map.put(attrs, :id, "r")),
               inspect(attrs)
      end

      assert {:error, :invalid_discount} =
               Discounts.normalize(%{method: :buy_x_pay_y, x: 3, y: 2})
    end
  end

  describe "best/3" do
    test "no rules, no discount" do
      assert %{discount: d, rule: nil} = best([], 1250, 2)
      assert minor(d) == 0
    end

    test "percent off rounds half-up on the line" do
      rule = rule!(%{method: :percent_off, rate: Decimal.new("0.15")})
      # 3 × 333 = 999; 15% = 149.85 → 150
      assert %{discount: d, rule: "r"} = best([rule], 333, 3)
      assert minor(d) == 150
    end

    test "unit price lowers each unit to the price, never raises it" do
      rule = rule!(%{method: :unit_price, price: m(900)})
      assert minor(best([rule], 1250, 2).discount) == 700
      assert %{rule: nil} = best([rule], 800, 2)
    end

    test "buy x pay y discounts whole bundles only" do
      rule = rule!(%{method: :buy_x_pay_y, x: 3, y: 2})
      assert minor(best([rule], 1000, 2).discount) == 0
      assert minor(best([rule], 1000, 7).discount) == 2000
    end

    test "x for an amount discounts whole bundles, never below zero" do
      rule = rule!(%{method: :x_for_amount, x: 2, amount: m(2000)})
      assert minor(best([rule], 1250, 5).discount) == 1000
      assert %{rule: nil} = best([rule], 900, 4)
    end

    test "rules do not stack: the largest discount wins, ties to the earlier rule" do
      a = rule!(%{id: "a", method: :percent_off, rate: Decimal.new("0.10")})
      b = rule!(%{id: "b", method: :buy_x_pay_y, x: 2, y: 1})
      c = rule!(%{id: "c", method: :unit_price, price: m(400)})
      assert %{rule: "c"} = best([a, b, c], 1000, 2)
      assert minor(best([a, b, c], 1000, 2).discount) == 1200

      tie = rule!(%{id: "tie", method: :unit_price, price: m(400)})
      assert %{rule: "c"} = best([a, c, tie], 1000, 2)
    end

    test "conditions: enabled, weekday, hours (with overnight) and minimum quantity" do
      base = %{method: :percent_off, rate: Decimal.new("0.5")}

      assert %{rule: nil} = best([rule!(Map.put(base, :enabled, false))], 1000, 1)
      assert %{rule: nil} = best([rule!(Map.put(base, :weekdays, [6, 7]))], 1000, 1)
      assert %{rule: "r"} = best([rule!(Map.put(base, :weekdays, [2]))], 1000, 1)
      assert %{rule: "r"} = best([rule!(Map.put(base, :hours, {11, 14}))], 1000, 1)
      assert %{rule: nil} = best([rule!(Map.put(base, :hours, {13, 14}))], 1000, 1)
      assert %{rule: nil} = best([rule!(Map.put(base, :min_quantity, 2))], 1000, 1)

      night = rule!(Map.put(base, :hours, {22, 2}))
      assert %{rule: "r"} = best([night], 1000, 1, %{weekday: 2, hour: 23})
      assert %{rule: "r"} = best([night], 1000, 1, %{weekday: 2, hour: 1})
      assert %{rule: nil} = best([night], 1000, 1, @noon_tue)
    end

    test "a rule priced in another currency never applies" do
      rule = rule!(%{method: :unit_price, price: m(100, :EUR)})
      assert %{rule: nil} = best([rule], 1000, 1)
    end
  end

  defp rule_gen do
    one_of([
      map(integer(1..100), &%{method: :percent_off, rate: Decimal.div(&1, 100)}),
      map(integer(0..5000), &%{method: :unit_price, price: m(&1)}),
      bind(integer(2..6), fn x ->
        map(integer(1..(x - 1)), &%{method: :buy_x_pay_y, x: x, y: &1})
      end),
      map({integer(2..6), integer(1..20_000)}, fn {x, a} ->
        %{method: :x_for_amount, x: x, amount: m(a)}
      end)
    ])
    |> bind(fn attrs ->
      map({boolean(), integer(1..4), member_of([:any, {9, 17}, {22, 2}])}, fn {on, minq, hours} ->
        Map.merge(attrs, %{enabled: on, min_quantity: minq, hours: hours})
      end)
    end)
  end

  defp rules_gen do
    map(list_of(rule_gen(), max_length: 5), fn list ->
      list |> Enum.with_index() |> Enum.map(fn {a, i} -> rule!(Map.put(a, :id, "r#{i}")) end)
    end)
  end

  defp at_gen, do: map({integer(1..7), integer(0..23)}, fn {d, h} -> %{weekday: d, hour: h} end)

  property "0 ≤ discount ≤ line, and Pricing accepts the discounted line" do
    check all(
            rules <- rules_gen(),
            unit <- integer(1..5000),
            qty <- integer(1..20),
            at <- at_gen()
          ) do
      %{discount: d} = best(rules, unit, qty, at)
      assert minor(d) in 0..(unit * qty)

      line = %{unit_price: m(unit), quantity: qty, discount: d}
      zero = m(0)
      adj = %{discount_total: zero, tax_total: zero, delivery_fee: zero, tip: zero}
      assert {:ok, _} = Pricing.price(:USD, [line], adj)
    end
  end

  property "the chosen rule is optimal over each rule alone, and order does not change the amount" do
    check all(
            rules <- rules_gen(),
            unit <- integer(1..5000),
            qty <- integer(1..20),
            at <- at_gen()
          ) do
      %{discount: d, rule: id} = best(rules, unit, qty, at)
      singles = for r <- rules, do: minor(best([r], unit, qty, at).discount)
      assert minor(d) == Enum.max([0 | singles])
      assert id == nil == (minor(d) == 0)
      assert minor(best(Enum.reverse(rules), unit, qty, at).discount) == minor(d)
    end
  end

  property "hour windows: inclusive, wrapping past midnight when from > to" do
    check all(from <- integer(0..23), to <- integer(0..23), hour <- integer(0..23)) do
      rule = rule!(%{method: :percent_off, rate: Decimal.new("0.5"), hours: {from, to}})
      inside = if from <= to, do: hour in from..to//1, else: hour >= from or hour <= to
      assert best([rule], 1000, 1, %{weekday: 1, hour: hour}).rule == "r" == inside
    end
  end
end
