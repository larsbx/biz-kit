defmodule CommerceCore.TaxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.Tax

  defp m(currency, minor), do: Money.from_integer(minor, currency)
  defp minor(money), do: money |> Money.to_integer_exp() |> elem(1)

  defp profile(rate, fee_taxable? \\ false),
    do: %{rate: Decimal.new(rate), fee_taxable?: fee_taxable?}

  describe "flat/4" do
    test "a $10.00 pizza at 8.875% carries $0.89 of tax" do
      assert {:ok, tax} = Tax.flat(:USD, profile("0.08875"), [m(:USD, 1000)], m(:USD, 0))
      assert Money.equal?(tax.total, m(:USD, 89))
      assert [line] = tax.lines
      assert Money.equal?(line, m(:USD, 89))
      assert Money.equal?(tax.fee, m(:USD, 0))
    end

    test "three $3.33 lines at 8.875% split the order's rounded tax exactly" do
      lines = List.duplicate(m(:USD, 333), 3)
      assert {:ok, tax} = Tax.flat(:USD, profile("0.08875"), lines, m(:USD, 0))

      # 999 × 0.08875 = 88.66… rounds once to 89; the remainder goes to the
      # largest fractional parts, first lines first on ties.
      assert Money.equal?(tax.total, m(:USD, 89))
      assert Enum.map(tax.lines, &minor/1) == [30, 30, 29]
    end

    test "an exact half rounds up" do
      assert {:ok, tax} = Tax.flat(:USD, profile("0.1"), [m(:USD, 5)], m(:USD, 0))
      assert Money.equal?(tax.total, m(:USD, 1))
    end

    test "the extra unit goes to the largest remainder, not the first line" do
      # 100 × ½ = 50 exactly; 199 × ½ = 99.5; the order's 149.5 rounds to 150.
      assert {:ok, tax} = Tax.flat(:USD, profile("0.5"), [m(:USD, 100), m(:USD, 199)], m(:USD, 0))
      assert Enum.map(tax.lines, &minor/1) == [50, 100]
    end

    test "the delivery fee is taxed only where the profile says so" do
      lines = [m(:USD, 1000)]

      assert {:ok, untaxed} = Tax.flat(:USD, profile("0.1"), lines, m(:USD, 500))
      assert Money.equal?(untaxed.fee, m(:USD, 0))
      assert Money.equal?(untaxed.total, m(:USD, 100))

      assert {:ok, taxed} = Tax.flat(:USD, profile("0.1", true), lines, m(:USD, 500))
      assert Money.equal?(taxed.fee, m(:USD, 50))
      assert Money.equal?(taxed.total, m(:USD, 150))
    end

    test "zero-exponent currencies round in whole units" do
      assert {:ok, tax} = Tax.flat(:CLP, profile("0.19"), [m(:CLP, 12_500)], m(:CLP, 0))
      assert Money.equal?(tax.total, m(:CLP, 2375))
    end

    test "rejects what it cannot tax" do
      line = m(:USD, 100)
      zero = m(:USD, 0)

      assert {:error, :no_lines} = Tax.flat(:USD, profile("0.1"), [], zero)
      assert {:error, :invalid_rate} = Tax.flat(:USD, profile("-0.01"), [line], zero)
      assert {:error, :invalid_rate} = Tax.flat(:USD, profile("1"), [line], zero)

      assert {:error, :invalid_rate} =
               Tax.flat(:USD, %{rate: 0.1, fee_taxable?: false}, [line], zero)

      assert {:error, {:currency_mismatch, :EUR}} =
               Tax.flat(:USD, profile("0.1"), [m(:EUR, 100)], zero)

      assert {:error, {:negative_amount, {:line, 1}}} =
               Tax.flat(:USD, profile("0.1"), [line, m(:USD, -1)], zero)

      assert {:error, {:negative_amount, :delivery_fee}} =
               Tax.flat(:USD, profile("0.1", true), [line], m(:USD, -1))
    end
  end

  describe "reverse/4" do
    test "a 50% refund reverses 50% of the tax" do
      # $10.89 paid, of which $0.89 tax; refunding $5.445 → half-up 45¢ reversed.
      assert {:ok, reversed} = Tax.reverse(m(:USD, 89), m(:USD, 1089), m(:USD, 0), m(:USD, 545))
      assert Money.equal?(reversed, m(:USD, 45))
    end

    test "the refunds of a whole order reverse exactly its tax" do
      tax = m(:USD, 89)
      total = m(:USD, 1089)

      {:ok, first} = Tax.reverse(tax, total, m(:USD, 0), m(:USD, 436))
      {:ok, rest} = Tax.reverse(tax, total, m(:USD, 436), m(:USD, 653))

      assert minor(first) + minor(rest) == 89
    end

    test "a free order has no tax to reverse" do
      assert {:ok, reversed} = Tax.reverse(m(:USD, 0), m(:USD, 0), m(:USD, 0), m(:USD, 0))
      assert Money.equal?(reversed, m(:USD, 0))
    end

    test "rejects refunds beyond what was paid" do
      assert {:error, :refund_exceeds_total} =
               Tax.reverse(m(:USD, 89), m(:USD, 1089), m(:USD, 1000), m(:USD, 90))

      assert {:error, {:negative_amount, :refund}} =
               Tax.reverse(m(:USD, 89), m(:USD, 1089), m(:USD, 0), m(:USD, -1))
    end
  end

  # Rates are the exact decimals owners enter: up to 5 places, below 100%.
  defp rate, do: map(integer(0..99_999), &Decimal.div(Decimal.new(&1), Decimal.new(100_000)))
  defp currency, do: member_of([:USD, :EUR, :CLP])

  property "I₇: the order's tax is its rounded exact tax, split exactly and fairly" do
    check all(
            currency <- currency(),
            r <- rate(),
            fee_taxable? <- boolean(),
            bases <- list_of(integer(0..100_000), min_length: 1, max_length: 12),
            fee <- integer(0..5_000)
          ) do
      {:ok, tax} =
        Tax.flat(
          currency,
          %{rate: r, fee_taxable?: fee_taxable?},
          Enum.map(bases, &m(currency, &1)),
          m(currency, fee)
        )

      shares = Enum.map(tax.lines, &minor/1) ++ [minor(tax.fee)]
      taxed = bases ++ [if(fee_taxable?, do: fee, else: 0)]
      exact = Enum.map(taxed, &Decimal.mult(&1, r))
      order_exact = Enum.reduce(exact, Decimal.new(0), &Decimal.add/2)

      assert Enum.sum(shares) == minor(tax.total)
      assert minor(tax.total) == order_exact |> Decimal.round(0, :half_up) |> Decimal.to_integer()
      assert Enum.all?(shares, &(&1 >= 0))

      # Largest remainder: each share is its exact tax rounded down, or up by
      # one, and every share rounded up had a remainder at least as large as
      # every share rounded down.
      {up, down} =
        shares
        |> Enum.zip(exact)
        |> Enum.map(fn {share, e} ->
          floor = e |> Decimal.round(0, :floor) |> Decimal.to_integer()
          assert share in [floor, floor + 1]
          {share == floor + 1, Decimal.sub(e, floor)}
        end)
        |> Enum.split_with(&elem(&1, 0))

      for {_, ru} <- up, {_, rd} <- down, do: assert(not Decimal.lt?(ru, rd))
    end
  end

  property "refunds in any order and any split reverse exactly the order's tax" do
    check all(
            tax <- integer(0..20_000),
            extra <- integer(1..200_000),
            cuts <- list_of(integer(0..1_000), min_length: 1, max_length: 8)
          ) do
      total = tax + extra
      refunds = split(total, cuts)

      {reversals, ^total} =
        Enum.map_reduce(refunds, 0, fn refund, before ->
          {:ok, r} = Tax.reverse(m(:USD, tax), m(:USD, total), m(:USD, before), m(:USD, refund))
          {minor(r), before + refund}
        end)

      assert Enum.all?(reversals, &(&1 >= 0))
      assert Enum.sum(reversals) == tax
    end
  end

  # Splits total into parts proportional to the cuts, summing exactly to total.
  defp split(total, cuts) do
    weight = Enum.sum(cuts) + length(cuts)
    parts = Enum.map(cuts, &div(total * (&1 + 1), weight))
    List.update_at(parts, -1, &(&1 + total - Enum.sum(parts)))
  end
end
