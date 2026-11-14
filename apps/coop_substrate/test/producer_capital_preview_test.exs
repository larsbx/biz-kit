defmodule CoopSubstrate.ProducerCapitalPreviewTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.ProducerCapitalPreview, as: Capital

  @now 1_800_000_000

  defp member_contribution do
    %{
      schema: "bizkit.producer-capital.annual-contribution-preview.v1",
      cooperative_id: "coop-1",
      member_business_id: "producer-1",
      membership_year: 2026,
      currency: "USD",
      amount_minor: 25_000,
      capital_class: "membership_equity_candidate",
      source_ref: "receipt-2026-producer-1"
    }
  end

  defp project do
    %{
      schema: "bizkit.producer-capital.project-snapshot-preview.v1",
      project_id: "asset-project-1",
      producer_business_id: "producer-1",
      currency: "USD",
      revision: 3,
      issued_units: 10,
      positions: [
        %{owner_business_id: "producer-1", serials: [0, 1]},
        %{owner_business_id: "coop-1", serials: [2, 3, 4, 5, 6, 7]},
        %{owner_business_id: "investor-1", serials: [8, 9]}
      ],
      contract_profile: "diminishing_musharakah_asset_coownership",
      profile_version: 1,
      adopted_profile_ref: "doctrinal-adoption-M03",
      civil_review_ref: "jurisdiction-review-pending",
      title_ref: "title-source-serial-123",
      ordinary_loss_rule: "capital_ownership_proportionate",
      principal_guarantee: false
    }
  end

  defp buyout do
    %{
      schema: "bizkit.producer-capital.unit-buyout-preview.v1",
      project_id: "asset-project-1",
      expected_revision: 3,
      seller_business_id: "coop-1",
      buyer_business_id: "producer-1",
      serials: [2, 3],
      currency: "USD",
      per_unit_minor: 9_000,
      amount_minor: 18_000,
      valuation_ref: "appraisal-source-2026-11-13",
      appraisal_as_of: @now - 60,
      expires_at: @now + 600,
      seller_consent_ref: "consent-seller-specific",
      buyer_consent_ref: "consent-buyer-specific",
      settlement_ref: "consideration-unverified",
      transfer_kind: "separate_voluntary_current_value_unit_sale",
      principal_guarantee: false,
      fixed_return_minor: 0
    }
  end

  test "annual USD 250 capital contribution never issues shares or grants repayment" do
    assert {:ok, p} = Capital.annual_contribution(member_contribution())
    assert p.amount_minor == 25_000
    assert p.equity_units_issued == 0
    assert p.status == :held_for_legal_share_issuance_and_nav
    refute p.financial_authority
  end

  test "annual membership is not a guaranteed debt or automatically an investment" do
    for change <- [
          %{amount_minor: 24_999},
          %{capital_class: "refundable_debt"},
          %{capital_class: "optional_project_investment"},
          %{currency: "EUR"},
          %{membership_year: 2099, amount_minor: 25_001}
        ] do
      assert {:error, :invalid_annual_contribution} =
               Capital.annual_contribution(Map.merge(member_contribution(), change))
    end

    assert {:error, :invalid_annual_contribution} =
             Capital.annual_contribution(Map.put(member_contribution(), :guaranteed_yield, 1))
  end

  test "separate, fair-value unit sale conserves exact serial title ownership" do
    assert {:ok, p} = Capital.buyout(project(), buyout(), @now)

    assert p.issued_units == 10
    assert p.source_revision == 3
    assert p.proposed_revision == 4
    assert p.consideration_minor == 18_000

    assert Enum.find(p.positions_after, &(&1.owner_business_id == "producer-1")).serials ==
             [0, 1, 2, 3]

    assert Enum.find(p.positions_after, &(&1.owner_business_id == "coop-1")).serials ==
             [4, 5, 6, 7]

    before_serials =
      Enum.flat_map(p.positions_before, & &1.serials) |> Enum.sort()

    after_serials =
      Enum.flat_map(p.positions_after, & &1.serials) |> Enum.sort()

    assert before_serials == after_serials
    assert before_serials == Enum.to_list(0..9)
    assert p.status == :unadmitted_requires_independent_evidence_and_authority
    refute p.legal_effect
    refute p.accounting_posted
    refute p.funds_moved
    refute p.title_transferred
  end

  test "seller must own precisely the existing units and producer is sole buyer" do
    for change <- [
          %{serials: [2, 2]},
          %{serials: [0]},
          %{serials: [2, 15]},
          %{seller_business_id: "unknown"},
          %{seller_business_id: "producer-1"},
          %{buyer_business_id: "investor-1"}
        ] do
      assert {:error, :invalid_buyout_terms} =
               Capital.buyout(project(), Map.merge(buyout(), change), @now)
    end
  end

  test "valuation and consideration bind price, currency, version and expiry" do
    for change <- [
          %{amount_minor: 20_000},
          %{per_unit_minor: 0},
          %{per_unit_minor: 9_000.0},
          %{amount_minor: 1.2},
          %{currency: "EUR"},
          %{expected_revision: 2},
          %{expires_at: @now},
          %{appraisal_as_of: @now + 1},
          %{valuation_ref: ""},
          %{seller_consent_ref: ""}
        ] do
      assert {:error, :invalid_buyout_terms} =
               Capital.buyout(project(), Map.merge(buyout(), change), @now)
    end
  end

  test "no guaranteed par redemption, fixed return, compelled sale, or hidden fields" do
    for change <- [
          %{principal_guarantee: true},
          %{fixed_return_minor: 100},
          %{transfer_kind: "compulsory_par_redemption"},
          %{transfer_kind: "interest_bearing_loan"}
        ] do
      assert {:error, :invalid_buyout_terms} =
               Capital.buyout(project(), Map.merge(buyout(), change), @now)
    end

    assert {:error, :invalid_buyout_terms} =
             Capital.buyout(project(), Map.put(buyout(), :interest_rate, 5), @now)
  end

  test "opening project refuses bad serial partition, double allocation or guarantee" do
    for change <- [
          %{issued_units: 11},
          %{positions: [hd(project().positions), hd(project().positions)]},
          %{positions: [%{owner_business_id: "producer-1", serials: Enum.to_list(0..9)}]},
          %{principal_guarantee: true},
          %{contract_profile: "mudarabah"},
          %{ordinary_loss_rule: "investor_guaranteed"}
        ] do
      assert {:error, :invalid_project_snapshot} =
               Capital.buyout(Map.merge(project(), change), buyout(), @now)
    end
  end

  test "same candidate is stable under shuffled ownership rows and serial order" do
    assert {:ok, original} = Capital.buyout(project(), buyout(), @now)
    reordered = %{project() | positions: Enum.reverse(project().positions)}
    shuffled = %{buyout() | serials: Enum.reverse(buyout().serials)}
    assert {:ok, same} = Capital.buyout(reordered, shuffled, @now)
    assert original.terms_digest == same.terms_digest
    assert original.positions_after == same.positions_after
  end

  test "changed source revisions and legal or valuation evidence change the candidate" do
    assert {:ok, a} = Capital.buyout(project(), buyout(), @now)

    assert {:ok, b} =
             Capital.buyout(%{project() | revision: 4}, %{buyout() | expected_revision: 4}, @now)

    assert {:ok, c} =
             Capital.buyout(project(), %{buyout() | valuation_ref: "different-appraisal"}, @now)

    assert {:ok, d} =
             Capital.buyout(project(), %{buyout() | settlement_ref: "different-receipt"}, @now)

    refute a.terms_digest == b.terms_digest
    refute a.terms_digest == c.terms_digest
    refute a.terms_digest == d.terms_digest
  end

  test "a second purchase cannot use same spent units in the next snapshot" do
    assert {:ok, moved} = Capital.buyout(project(), buyout(), @now)

    next_project = %{
      project()
      | revision: moved.proposed_revision,
        positions: moved.positions_after
    }

    assert {:error, :invalid_buyout_terms} =
             Capital.buyout(next_project, %{buyout() | expected_revision: 4}, @now)
  end

  test "even valid inputs never admit a capital or financial action" do
    assert {:error, :invalid_buyout} = Capital.buyout(project(), buyout(), -1)
    assert {:error, :invalid_buyout} = Capital.buyout(nil, buyout(), @now)
    assert {:error, :invalid_annual_contribution} = Capital.annual_contribution(nil)
  end
end
