defmodule CommerceCore.PricingTest do
  use ExUnit.Case, async: true

  alias CommerceCore.Pricing

  defp m(currency, minor), do: Money.from_integer(minor, currency)

  defp zero(c),
    do: %{
      discount_total: m(c, 0),
      tax_total: m(c, 0),
      delivery_fee: m(c, 0),
      tip: m(c, 0)
    }

  test "computes exact commercial totals without changing currencies" do
    line = %{unit_price: m(:USD, 1250), quantity: 2, discount: m(:USD, 100)}

    adjustments = %{
      discount_total: m(:USD, 50),
      tax_total: m(:USD, 213),
      delivery_fee: m(:USD, 300),
      tip: m(:USD, 400)
    }

    assert {:ok, result} = Pricing.price(:USD, [line], adjustments)
    assert Money.equal?(result.lines |> hd() |> Map.fetch!(:subtotal), m(:USD, 2400))
    assert Money.equal?(result.subtotal, m(:USD, 2400))
    assert Money.equal?(result.total, m(:USD, 3263))
  end

  test "rejects invalid totals with the existing Eatsbot error terms" do
    line = %{unit_price: m(:EUR, 100), quantity: 2, discount: m(:EUR, 0)}

    assert {:error, :no_lines} = Pricing.price(:EUR, [], zero(:EUR))

    assert {:error, {:invalid_quantity, 0}} =
             Pricing.price(:EUR, [%{line | quantity: 0}], zero(:EUR))

    assert {:error, {:discount_exceeds_line, 0}} =
             Pricing.price(:EUR, [%{line | discount: m(:EUR, 201)}], zero(:EUR))

    assert {:error, :negative_total} =
             Pricing.price(:EUR, [line], %{zero(:EUR) | discount_total: m(:EUR, 201)})

    assert {:error, {:currency_mismatch, :USD}} =
             Pricing.price(:EUR, [line], %{zero(:EUR) | tax_total: m(:USD, 1)})

    assert {:error, {:negative_amount, :tip}} =
             Pricing.price(:EUR, [line], %{zero(:EUR) | tip: m(:EUR, -1)})
  end

  test "works with differing currency exponents without converting" do
    for currency <- [:USD, :CLP, :EUR] do
      lines = [
        %{unit_price: m(currency, 100), quantity: 3, discount: m(currency, 20)},
        %{unit_price: m(currency, 70), quantity: 2, discount: m(currency, 0)}
      ]

      assert {:ok, priced} = Pricing.price(currency, lines, zero(currency))
      assert Money.equal?(priced.subtotal, m(currency, 420))
      assert Money.equal?(priced.total, m(currency, 420))
      assert Enum.all?(priced.lines, &(&1.subtotal.currency == currency))
    end
  end

  test "line ordering does not affect the order total" do
    lines = [
      %{unit_price: m(:USD, 250), quantity: 3, discount: m(:USD, 10)},
      %{unit_price: m(:USD, 120), quantity: 1, discount: m(:USD, 20)}
    ]

    assert {:ok, a} = Pricing.price(:USD, lines, zero(:USD))
    assert {:ok, b} = Pricing.price(:USD, Enum.reverse(lines), zero(:USD))
    assert Money.equal?(a.total, b.total)
  end
end
