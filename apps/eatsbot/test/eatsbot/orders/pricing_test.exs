defmodule EatsbotCore.Orders.PricingTest do
  @moduledoc """
  Properties of `Pricing.price/3`, the single place an order's amounts are derived (I₂).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias EatsbotCore.Orders.Pricing

  @currencies [:USD, :CLP, :EUR]

  defp money(currency, minor), do: Money.from_integer(minor, currency)

  # A line as minor-unit integers {unit, quantity, discount} with discount ≤ unit × quantity.
  defp raw_line_gen do
    gen all(
          unit <- integer(0..50_000),
          quantity <- integer(1..20),
          discount <- integer(0..(unit * quantity))
        ) do
      {unit, quantity, discount}
    end
  end

  defp order_gen do
    gen all(
          currency <- member_of(@currencies),
          raw <- list_of(raw_line_gen(), min_length: 1, max_length: 8),
          [fee, tip, tax] <- list_of(integer(0..10_000), length: 3),
          order_discount <- integer(0..Enum.sum(for {u, q, d} <- raw, do: u * q - d))
        ) do
      lines =
        for {u, q, d} <- raw,
            do: %{unit_price: money(currency, u), quantity: q, discount: money(currency, d)}

      {currency, lines,
       %{
         delivery_fee: money(currency, fee),
         tip: money(currency, tip),
         tax_total: money(currency, tax),
         discount_total: money(currency, order_discount)
       }}
    end
  end

  defp sum(currency, amounts), do: Enum.reduce(amounts, Money.zero(currency), &Money.add!(&2, &1))

  property "I₂: subtotal is the sum of line subtotals and total follows the formula" do
    check all({currency, lines, adj} <- order_gen()) do
      {:ok, priced} = Pricing.price(currency, lines, adj)

      for {line, input} <- Enum.zip(priced.lines, lines) do
        expected = input.unit_price |> Money.mult!(input.quantity) |> Money.sub!(input.discount)
        assert Money.equal?(line.subtotal, expected)
      end

      assert Money.equal?(priced.subtotal, sum(currency, Enum.map(priced.lines, & &1.subtotal)))

      expected_total =
        priced.subtotal
        |> Money.sub!(adj.discount_total)
        |> Money.add!(adj.tax_total)
        |> Money.add!(adj.delivery_fee)
        |> Money.add!(adj.tip)

      assert Money.equal?(priced.total, expected_total)
      refute Money.negative?(priced.total)
    end
  end

  property "pricing does not depend on line order" do
    check all({currency, lines, adj} <- order_gen(), shuffled <- constant(Enum.shuffle(lines))) do
      {:ok, a} = Pricing.price(currency, lines, adj)
      {:ok, b} = Pricing.price(currency, shuffled, adj)
      assert Money.equal?(a.total, b.total)
      assert Money.equal?(a.subtotal, b.subtotal)
    end
  end

  property "every amount in the result is in the order's currency" do
    check all({currency, lines, adj} <- order_gen()) do
      {:ok, priced} = Pricing.price(currency, lines, adj)
      amounts = [priced.subtotal, priced.total | Enum.map(priced.lines, & &1.subtotal)]
      assert Enum.all?(amounts, &(&1.currency == currency))
    end
  end

  property "an amount in another currency is rejected, never converted" do
    check all(
            {currency, [line | rest], adj} <- order_gen(),
            other <- member_of(@currencies -- [currency])
          ) do
      foreign = %{line | unit_price: Money.from_integer(1, other), discount: Money.zero(other)}

      assert Pricing.price(currency, [foreign | rest], adj) ==
               {:error, {:currency_mismatch, other}}

      assert Pricing.price(currency, [line | rest], %{adj | tip: Money.from_integer(1, other)}) ==
               {:error, {:currency_mismatch, other}}
    end
  end

  test "a line discount above the line's gross amount is rejected" do
    line = %{unit_price: money(:USD, 500), quantity: 2, discount: money(:USD, 1001)}

    assert Pricing.price(:USD, [line], zero_adjustments(:USD)) ==
             {:error, {:discount_exceeds_line, 0}}
  end

  test "an order discount that would make the total negative is rejected" do
    line = %{unit_price: money(:USD, 500), quantity: 1, discount: money(:USD, 0)}
    adj = %{zero_adjustments(:USD) | discount_total: money(:USD, 501)}
    assert Pricing.price(:USD, [line], adj) == {:error, :negative_total}
  end

  test "negative inputs and empty orders are rejected" do
    ok = %{unit_price: money(:USD, 500), quantity: 1, discount: money(:USD, 0)}
    assert Pricing.price(:USD, [], zero_adjustments(:USD)) == {:error, :no_lines}

    assert Pricing.price(:USD, [%{ok | quantity: 0}], zero_adjustments(:USD)) ==
             {:error, {:invalid_quantity, 0}}

    assert Pricing.price(:USD, [ok], %{zero_adjustments(:USD) | tip: money(:USD, -1)}) ==
             {:error, {:negative_amount, :tip}}
  end

  test "a worked example: $12.50 × 2, $1 line discount, $3 fee, $4 tip, $2.13 tax" do
    line = %{
      unit_price: Money.new!(:USD, "12.50"),
      quantity: 2,
      discount: Money.new!(:USD, "1.00")
    }

    adj = %{
      discount_total: Money.zero(:USD),
      tax_total: Money.new!(:USD, "2.13"),
      delivery_fee: Money.new!(:USD, "3.00"),
      tip: Money.new!(:USD, "4.00")
    }

    {:ok, priced} = Pricing.price(:USD, [line], adj)
    assert Money.equal?(priced.subtotal, Money.new!(:USD, "24.00"))
    assert Money.equal?(priced.total, Money.new!(:USD, "33.13"))
  end

  defp zero_adjustments(c),
    do: %{
      discount_total: Money.zero(c),
      tax_total: Money.zero(c),
      delivery_fee: Money.zero(c),
      tip: Money.zero(c)
    }
end
