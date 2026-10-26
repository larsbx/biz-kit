defmodule GroupBuyCoreTest do
  use ExUnit.Case, async: true

  alias GroupBuyCore, as: G

  @now 1_800_000_000

  defp offer(overrides \\ %{}) do
    Map.merge(
      %{
        id: "https://seller.example/group-buys/winter-tires",
        seller: "https://seller.example/actors/merchant",
        sku: "tire-225",
        unit: "piece",
        currency: "USD",
        revision: 3,
        expires_at: @now + 1_000,
        capacity: 20,
        solo_unit_minor: 10_000,
        tiers: [
          %{min_quantity: 5, unit_minor: 9_000},
          %{min_quantity: 10, unit_minor: 8_000}
        ]
      },
      overrides
    )
  end

  defp pledge(name, quantity, overrides \\ %{}) do
    Map.merge(
      %{
        id: "https://" <> name <> ".example/group-pledges/1",
        buyer: "https://" <> name <> ".example/actors/buyer",
        offer_id: offer().id,
        offer_revision: 3,
        quantity: quantity,
        max_group_unit_minor: 9_000,
        expires_at: @now + 900
      },
      overrides
    )
  end

  defp consents(quote) do
    Enum.map(quote.members, fn member ->
      %{
        actor: member.buyer,
        quote_hash: quote.quote_hash,
        evidence_ref: "signed-proof-must-be-verified-" <> member.pledge_id
      }
    end)
  end

  defp seller_consent(quote) do
    %{
      actor: quote.seller,
      quote_hash: quote.quote_hash,
      evidence_ref: "seller-acceptance-to-be-verified"
    }
  end

  test "before volume threshold, everyone keeps full-price cash checkout" do
    assert {:ok, quote} = G.quote(offer(), [pledge("a", 2), pledge("b", 1)], @now)
    assert quote.status == :collecting_no_group_commitment
    assert quote.active_quantity == 3
    assert quote.cash_unit_minor == 10_000
    assert quote.group_unit_minor == nil
    assert quote.totals == %{cash_minor: 30_000, group_minor: nil, savings_minor: nil}
    assert quote.next_tier == %{minimum: 5, more_units_needed: 2, unit_minor: 9_000}
    assert Enum.all?(quote.members, &(&1.payment_options == [:pay_cash, :join_group]))
    assert Enum.all?(quote.members, &(&1.group_minor == nil))
    assert quote.money_status == :not_collected

    assert {:error, :threshold_not_met} =
             G.commitment_preview(quote, seller_consent(quote), consents(quote), @now)
  end

  test "five units unlock a seller-funded tier and show exact per-buyer savings" do
    assert {:ok, quote} = G.quote(offer(), [pledge("a", 2), pledge("b", 3)], @now)
    assert quote.status == :pledged_volume_covered_purchase_option_available
    assert quote.group_unit_minor == 9_000
    assert quote.totals == %{cash_minor: 50_000, group_minor: 45_000, savings_minor: 5_000}
    assert Enum.map(quote.members, &{&1.quantity, &1.savings_minor}) == [{2, 2_000}, {3, 3_000}]
    assert quote.next_tier == %{minimum: 10, more_units_needed: 5, unit_minor: 8_000}
    assert quote.payment_option == :independent_cash_checkout_always_available
    assert quote.inventory_status == :not_reserved
  end

  test "ten units unlock a deeper discount shared across participating buyers" do
    buyers = [pledge("a", 4), pledge("b", 3), pledge("c", 3)]
    assert {:ok, quote} = G.quote(offer(), Enum.reverse(buyers), @now)
    assert quote.active_quantity == 10
    assert quote.group_unit_minor == 8_000
    assert quote.totals == %{cash_minor: 100_000, group_minor: 80_000, savings_minor: 20_000}
    assert quote.next_tier == nil
    assert Enum.all?(quote.members, &(&1.choice == :not_elected))
    assert {:ok, ^quote} = G.verify_quote(quote, @now)
    assert {:ok, other} = G.quote(offer(), buyers, @now)
    assert quote.quote_hash == other.quote_hash
    assert quote.members == other.members
  end

  test "purchase option stays disabled below threshold and for nonparticipating buyers" do
    {:ok, below} = G.quote(offer(), [pledge("a", 3)], @now)
    refute below.purchase_option_available
    assert {:error, :threshold_not_met} = G.purchase_option(below, pledge("a", 3).buyer, @now)

    {:ok, covered} = G.quote(offer(), [pledge("a", 2), pledge("b", 3)], @now)
    assert {:error, :buyer_not_in_pledges} =
             G.purchase_option(covered, "https://outsider.example/actors/buyer", @now)

    assert {:error, :invalid_or_stale_quote} =
             G.purchase_option(covered, pledge("a", 2).buyer, @now + 900)
  end

  test "lower prices disappear if pledged volume expires or seller revises prices" do
    a = pledge("a", 2)
    b = pledge("b", 3, %{expires_at: @now + 30})

    {:ok, covered} = G.quote(offer(), [a, b], @now)
    assert covered.purchase_option_available

    {:ok, below} = G.quote(offer(), [a, b], @now + 30)
    refute below.purchase_option_available
    assert below.active_quantity == 2
    assert {:error, :invalid_or_stale_quote} =
             G.purchase_option(covered, a.buyer, @now + 30)

    revised = offer(%{revision: 4, tiers: [%{min_quantity: 5, unit_minor: 8_500}]})
    assert {:error, :invalid_pledges} = G.quote(revised, [a, b], @now)
  end

  test "expired pledges never count toward quantity or charges" do
    one = pledge("a", 3)
    two = pledge("b", 3, %{expires_at: @now})
    assert {:ok, quote} = G.quote(offer(), [two, one], @now)
    assert quote.active_quantity == 3
    assert quote.expired_pledge_ids == [two.id]
    assert length(quote.members) == 1
    assert quote.group_unit_minor == nil
    assert quote.totals.cash_minor == 30_000
    assert quote.expires_at == one.expires_at

    assert {:error, :invalid_or_stale_quote} =
             G.verify_quote(quote, one.expires_at)
  end

  test "pledges cover volume to unlock the group purchase option without advance contracts" do
    {:ok, quote} = G.quote(offer(), [pledge("a", 2), pledge("b", 3)], @now)

    assert quote.purchase_option_available
    assert quote.coverage_basis == :active_member_pledges
    assert quote.price_authority == :group_price_offer_requires_checkout_authorization
    assert quote.contracted_quantity == 0

    assert {:ok, option} = G.purchase_option(quote, pledge("a", 2).buyer, @now)
    assert option.kind == :group_purchase_option_preview
    assert option.group_unit_minor == 9_000
    assert option.quantity == 2
    assert option.discounted_total_minor == 18_000
    assert option.ordinary_cash_total_minor == 20_000
    assert option.potential_savings_minor == 2_000
    assert option.checkout == :requires_fresh_membership_stock_and_payment_admission
    refute option.paid
    refute option.inventory_reserved

    assert {:ok, preview} =
             G.commitment_preview(quote, seller_consent(quote), consents(quote), @now)

    assert preview.status == :requires_independent_local_business_admission
    refute preview.inventory_reserved
    refute preview.payment_authorized
  end

  test "one absent buyer, wrong seller, or altered terms cannot authorize group" do
    {:ok, quote} = G.quote(offer(), [pledge("a", 2), pledge("b", 3)], @now)

    assert {:error, :invalid_consents} =
             G.commitment_preview(quote, seller_consent(quote), tl(consents(quote)), @now)

    assert {:error, :invalid_consents} =
             G.commitment_preview(
               quote,
               %{seller_consent(quote) | actor: "https://evil.example/actor"},
               consents(quote),
               @now
             )

    changed = %{quote | group_unit_minor: 1}

    assert {:error, :invalid_or_stale_quote} = G.verify_quote(changed, @now)

    {:ok, requote} = G.quote(offer(%{revision: 4}), [], @now)
    refute requote.quote_hash == quote.quote_hash
  end

  test "buyer ceiling, offer revisions, and seller origin fail closed" do
    assert {:error, :buyer_price_limit_exceeded} =
             G.quote(
               offer(),
               [pledge("a", 2, %{max_group_unit_minor: 8_500}), pledge("b", 3)],
               @now
             )

    assert {:error, :invalid_pledges} =
             G.quote(offer(), [pledge("a", 5, %{offer_revision: 2})], @now)

    assert {:error, :invalid_group_buy_offer} =
             G.quote(offer(%{seller: "https://evil.example/actors/merchant"}), [], @now)

    assert {:error, :invalid_group_buy_offer} =
             G.quote(offer(%{expires_at: @now}), [], @now)

    assert {:error, :invalid_group_buy_offer} =
             G.quote(offer(%{currency: "usd"}), [], @now)
  end

  test "duplicate id or buyer, extra private attributes and spoofed pledge owner refuse" do
    a = pledge("a", 3)
    assert {:error, :duplicate_pledge} = G.quote(offer(), [a, a], @now)

    assert {:error, :duplicate_buyer} =
             G.quote(offer(), [a, %{a | id: "https://a.example/group-pledges/2"}], @now)

    assert {:error, :invalid_pledges} =
             G.quote(offer(), [Map.put(a, :phone, "private")], @now)

    assert {:error, :invalid_pledges} =
             G.quote(offer(), [%{a | id: "https://forged.example/group-pledges/1"}], @now)
  end

  test "over-capacity refuses and integer-money overflow never wraps" do
    assert {:error, :oversubscribed} =
             G.quote(offer(), [pledge("a", 15), pledge("b", 6)], @now)

    assert {:error, :amount_overflow} =
             G.quote(
               offer(%{
                 solo_unit_minor: 9_007_199_254_740_991,
                 tiers: [%{min_quantity: 5, unit_minor: 8_000}]
               }),
               [pledge("a", 5)],
               @now
             )

    assert {:error, :invalid_pledges} =
             G.quote(offer(), [pledge("a", 1.5)], @now)
  end

  test "group pricing tiers must actually improve with increasing volume" do
    bad = [
      [%{min_quantity: 5, unit_minor: 10_000}],
      [%{min_quantity: 5, unit_minor: 9_000}, %{min_quantity: 5, unit_minor: 8_000}],
      [%{min_quantity: 5, unit_minor: 9_000}, %{min_quantity: 10, unit_minor: 9_000}],
      [%{min_quantity: 5, unit_minor: 9_000}, %{min_quantity: 21, unit_minor: 8_000}],
      [%{min_quantity: 5, unit_minor: 0}]
    ]

    for tiers <- bad do
      assert {:error, :invalid_group_buy_offer} = G.quote(offer(%{tiers: tiers}), [], @now)
    end
  end

  test "empty group has no fake discount or implied company" do
    assert {:ok, q} = G.quote(offer(), [], @now)
    assert q.active_quantity == 0
    assert q.members == []
    assert q.totals == %{cash_minor: 0, group_minor: nil, savings_minor: nil}
    assert q.status == :collecting_no_group_commitment

    assert {:error, :threshold_not_met} =
             G.commitment_preview(q, seller_consent(q), [], @now)
  end

  test "no arbitrary four-buyer limit; one hundred independently priced pledges" do
    n = 100
    many = for i <- 1..n, do: pledge("buyer" <> Integer.to_string(i), 1)

    campaign =
      offer(%{
        capacity: 120,
        tiers: [
          %{min_quantity: 5, unit_minor: 9_000},
          %{min_quantity: 80, unit_minor: 7_000}
        ]
      })

    assert {:ok, q} = G.quote(campaign, many, @now)
    assert q.active_quantity == n
    assert length(q.members) == n
    assert q.group_unit_minor == 7_000
    assert q.totals.group_minor == 700_000
  end
end
