defmodule EatsbotCore.Marketing.AttributionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias EatsbotCore.Marketing.Attribution

  @t0 ~U[2026-09-22 12:00:00Z]
  @hour 3600
  @window 24 * @hour

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  describe "attributed?/4" do
    test "never notified ⇒ not attributed" do
      refute Attribution.attributed?(nil, nil, @t0, @window)
    end

    test "check-in within the window after a notification ⇒ attributed" do
      assert Attribution.attributed?(@t0, nil, at(2 * @hour), @window)
      assert Attribution.attributed?(@t0, nil, at(@window), @window)
    end

    test "check-in after the window ⇒ not attributed" do
      refute Attribution.attributed?(@t0, nil, at(@window + 1), @window)
    end

    test "check-in before the notification ⇒ not attributed" do
      refute Attribution.attributed?(@t0, nil, at(-1), @window)
    end

    test "a notification credits at most one visit" do
      refute Attribution.attributed?(@t0, at(@hour), at(2 * @hour), @window)
    end

    test "a newer notification credits a new visit" do
      assert Attribution.attributed?(at(3 * @hour), at(@hour), at(4 * @hour), @window)
    end

    property "∀ check-in sequence: #attributed ≤ #notifications" do
      check all(offsets <- list_of(integer(0..(3 * @window)), max_length: 30)) do
        checkins = offsets |> Enum.sort() |> Enum.map(&at/1)

        {credited, _last} =
          Enum.reduce(checkins, {0, nil}, fn checked_in_at, {n, last} ->
            if Attribution.attributed?(@t0, last, checked_in_at, @window),
              do: {n + 1, checked_in_at},
              else: {n, last}
          end)

        assert credited <= 1
      end
    end
  end

  describe "commission/2" do
    test "applies the rate and rounds to the currency's minor unit" do
      assert Money.equal?(
               Attribution.commission(Money.new!(:CLP, 12_345), Decimal.new("0.05")),
               Money.new!(:CLP, 617)
             )

      assert Money.equal?(
               Attribution.commission(
                 Money.new!(:USD, Decimal.new("10.10")),
                 Decimal.new("0.075")
               ),
               Money.new!(:USD, Decimal.new("0.76"))
             )
    end

    test "zero rate ⇒ zero commission" do
      assert Money.zero?(Attribution.commission(Money.new!(:CLP, 5000), Decimal.new(0)))
    end

    property "0 ≤ rate ≤ 1 ⇒ 0 ≤ commission ≤ amount, same currency" do
      check all(
              amount <- integer(0..10_000_000),
              bps <- integer(0..10_000)
            ) do
        money = Money.new!(:CLP, amount)
        commission = Attribution.commission(money, Decimal.div(bps, 10_000))

        assert commission.currency == :CLP
        refute Money.negative?(commission)
        assert Money.compare!(commission, money) != :gt
      end
    end

    property "commission is monotone in the amount" do
      check all(
              a <- integer(0..1_000_000),
              b <- integer(0..1_000_000),
              bps <- integer(0..10_000)
            ) do
        rate = Decimal.div(bps, 10_000)
        [lo, hi] = Enum.sort([a, b])

        assert Money.compare!(
                 Attribution.commission(Money.new!(:CLP, lo), rate),
                 Attribution.commission(Money.new!(:CLP, hi), rate)
               ) != :gt
      end
    end
  end

  describe "redeemable?/3" do
    test "an open visit is redeemable inside the window only" do
      visit = %{status: :checked_in, checked_in_at: @t0}

      assert Attribution.redeemable?(visit, at(@hour), 2 * @hour)
      refute Attribution.redeemable?(visit, at(2 * @hour + 1), 2 * @hour)
    end

    test "a redeemed visit is never redeemable again" do
      refute Attribution.redeemable?(%{status: :redeemed, checked_in_at: @t0}, @t0, @window)
    end
  end

  describe "statement/1" do
    test "sums commissions per currency" do
      visits = [
        %{commission: Money.new!(:CLP, 100)},
        %{commission: Money.new!(:CLP, 250)},
        %{commission: Money.new!(:USD, Decimal.new("1.50"))},
        %{commission: nil}
      ]

      assert %{CLP: clp, USD: usd} = Attribution.statement(visits)
      assert Money.equal?(clp, Money.new!(:CLP, 350))
      assert Money.equal?(usd, Money.new!(:USD, Decimal.new("1.50")))
    end

    test "empty ⇒ empty" do
      assert Attribution.statement([]) == %{}
    end
  end

  describe "code/1" do
    property "codes use an unambiguous, deep-link-safe alphabet" do
      check all(len <- integer(4..16)) do
        code = Attribution.code(len)
        assert String.length(code) == len
        assert code =~ ~r/\A[23456789ABCDEFGHJKMNPQRSTUVWXYZ]+\z/
      end
    end
  end
end
