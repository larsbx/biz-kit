defmodule BarterCore.PricedExchangeTest do
  use ExUnit.Case, async: true

  alias BarterCore.PooledClearing
  alias BarterCore.PricedExchange, as: Pricing

  @now 1_800_000_000

  defp asset(code, unit, quantity),
    do: %{code: code, unit: unit, quantity: quantity}

  defp member(name, supplies, needs, rev \\ 1) do
    %{
      actor: "https://#{name}.example/actors/trader",
      revision: rev,
      valid_until: @now + 1_000,
      supplies: supplies,
      needs: needs
    }
  end

  defp offer(member, asset, cash_unit, discount_unit, currency \\ "USD") do
    %{
      seller: member.actor,
      code: asset.code,
      unit: asset.unit,
      currency: currency,
      cash_unit_minor: cash_unit,
      network_discount_unit_minor: discount_unit,
      revision: member.revision,
      valid_until: @now + 500
    }
  end

  defp fixture do
    [
      member("a", [asset("grain", "kg", 5)], [asset("milk", "l", 3)]),
      member("b", [asset("milk", "l", 6)], [asset("grain", "kg", 5)])
    ]
  end

  defp offers([a, b]) do
    [offer(a, hd(a.supplies), 1_000, 100), offer(b, hd(b.supplies), 500, 50)]
  end

  test "every in-network opportunity retains a real full-price payment option" do
    members = fixture()
    assert {:ok, plan} = PooledClearing.optimize(members, @now)
    assert {:ok, quoted} = Pricing.quote(plan, offers(members), @now)

    assert quoted.cash_option == :direct_payment_to_original_supplier
    assert quoted.network_option == :seller_discount_and_conditional_member_netting
    assert quoted.payment_status == :not_authorized_or_collected
    assert quoted.choice == :not_elected_requires_explicit_member_consent

    assert Enum.all?(quoted.priced_transfers, fn leg ->
             leg.options == [:network_opportunity, :pay_cash] and
               leg.cash_minor > leg.network_minor and
               leg.cash_minor - leg.network_minor == leg.incentive_minor
           end)

    assert Enum.map(quoted.priced_transfers, fn leg ->
             {leg.asset.code, leg.cash_minor, leg.network_minor}
           end) == [{"grain", 5_000, 4_500}, {"milk", 1_500, 1_350}]
  end

  test "network incentive is seller-funded and exact per-currency netting sums to zero" do
    members = fixture()
    {:ok, plan} = PooledClearing.optimize(members, @now)
    {:ok, quote} = Pricing.quote(plan, offers(members), @now)

    rows = quote.balances
    assert Enum.sum(Enum.map(rows, & &1.discount_granted_minor)) == 650
    assert Enum.sum(Enum.map(rows, & &1.savings_offered_minor)) == 650

    assert Enum.sum(Enum.map(rows, & &1.conditional_net_due_minor)) ==
             Enum.sum(Enum.map(rows, & &1.conditional_net_receivable_minor))

    assert Enum.all?(rows, &(&1.status == :preview_not_ledger_entry))
    assert Enum.any?(rows, &(&1.conditional_net_due_minor > 0))
    assert Enum.any?(rows, &(&1.conditional_net_receivable_minor > 0))
  end

  test "two currencies are never silently converted or netted against each other" do
    members = fixture()
    [one, two] = offers(members)
    {:ok, plan} = PooledClearing.optimize(members, @now)
    {:ok, result} = Pricing.quote(plan, [one, %{two | currency: "EUR"}], @now)

    assert Enum.sort(Enum.uniq(Enum.map(result.balances, & &1.currency))) == ["EUR", "USD"]

    for currency <- ["EUR", "USD"] do
      rows = Enum.filter(result.balances, &(&1.currency == currency))

      assert Enum.sum(Enum.map(rows, & &1.conditional_net_due_minor)) ==
               Enum.sum(Enum.map(rows, & &1.conditional_net_receivable_minor))
    end
  end

  test "unpriced supply and missing seller opt-in are refused, not invented" do
    members = fixture()
    {:ok, plan} = PooledClearing.optimize(members, @now)
    [a, b] = offers(members)
    assert {:error, :missing_or_unowned_price_offer} = Pricing.quote(plan, [a], @now)

    assert {:error, :missing_or_unowned_price_offer} =
             Pricing.quote(plan, [a, %{b | code: "phantom"}], @now)

    assert {:error, :duplicate_price_offer} = Pricing.quote(plan, [a, a, b], @now)

    assert {:error, :invalid_price_offers} =
             Pricing.quote(plan, [a, Map.put(b, :bank_account, "private")], @now)
  end

  test "quoted prices bind same seller source revision and finite expiry" do
    members = fixture()
    [a, b] = offers(members)
    {:ok, plan} = PooledClearing.optimize(members, @now)
    {:ok, quote} = Pricing.quote(plan, [a, b], @now)

    assert {:ok, ^quote} = Pricing.quote(plan, [b, a], @now)
    assert {:ok, changed} = Pricing.quote(plan, [%{a | cash_unit_minor: 1_001}, b], @now)
    refute changed.quote_hash == quote.quote_hash

    assert {:error, :invalid_price_offers} =
             Pricing.quote(plan, [%{a | revision: 2}, b], @now)

    assert {:error, :invalid_price_offers} =
             Pricing.quote(plan, [a, %{b | valid_until: @now}], @now)
  end

  test "discounts cannot exceed listed price, be negative or use floats" do
    members = fixture()
    [a, b] = offers(members)
    {:ok, plan} = PooledClearing.optimize(members, @now)

    for variant <- [
          %{a | network_discount_unit_minor: 1_001},
          %{a | network_discount_unit_minor: -1},
          %{a | network_discount_unit_minor: 0.5},
          %{a | cash_unit_minor: -10},
          %{a | currency: "usd"}
        ] do
      assert {:error, :invalid_price_offers} = Pricing.quote(plan, [variant, b], @now)
    end
  end

  test "a zero discount still has voluntary payment and in-network participation" do
    members = fixture()
    discounted = Enum.map(offers(members), &%{&1 | network_discount_unit_minor: 0})
    {:ok, plan} = PooledClearing.optimize(members, @now)
    {:ok, quote} = Pricing.quote(plan, discounted, @now)

    assert Enum.all?(quote.priced_transfers, fn leg ->
             leg.cash_minor == leg.network_minor and leg.incentive_minor == 0 and
               :pay_cash in leg.options
           end)
  end

  test "fixed-width money bounds and source plan tampering fail closed" do
    members = fixture()
    [a, b] = offers(members)
    {:ok, plan} = PooledClearing.optimize(members, @now)

    assert {:error, :amount_overflow} =
             Pricing.quote(plan, [%{a | cash_unit_minor: 9_007_199_254_740_991}, b], @now)

    assert {:error, :invalid_pooled_plan} =
             Pricing.quote(%{plan | terms_hash: "forged"}, [a, b], @now)
  end

  test "every available supply is priced even when it has no matched recipient" do
    members = fixture()
    [a, b] = offers(members)

    spare = asset("wood", "piece", 4)
    [first, second] = members
    extended = [%{first | supplies: first.supplies ++ [spare]}, second]
    {:ok, plan} = PooledClearing.optimize(extended, @now)

    assert {:error, :missing_or_unowned_price_offer} =
             Pricing.quote(plan, [a, b], @now)

    assert {:ok, _} =
             Pricing.quote(plan, [a, b, offer(first, spare, 600, 50)], @now)
  end
end
