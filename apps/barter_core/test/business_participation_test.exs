defmodule BarterCore.BusinessParticipationTest do
  use ExUnit.Case, async: true

  alias BarterCore.BusinessParticipation, as: Participation

  @now 1_800_000_000
  @business_id "https://a.example/entities/registered-merchant"
  @principal_id "prn_" <> String.duplicate("a", 26)

  defp business do
    %{
      business_id: @business_id,
      business_kind: :registered_cooperative,
      registration_ref: "https://registry.example/records/100",
      registration_revision: 2,
      registration_valid_until: @now + 1_000,
      registration_state: :current,
      sanctions_state: :clear
    }
  end

  defp agent do
    %{
      principal_id: @principal_id,
      business_id: @business_id,
      grant_ref: "https://a.example/grants/agent-1",
      grant_revision: 3,
      grant_state: :active,
      scopes: [:publish_supply, :approve_trade, :cross_border_reciprocal_fulfillment],
      expires_at: @now + 100
    }
  end

  test "only a business counterparty and scoped agent have a positive inert preflight" do
    assert {:ok, result} =
             Participation.preflight(business(), agent(), :publish_supply, @now)

    assert result.business_id == @business_id
    assert result.principal_id == @principal_id
    assert result.registration_revision == 2
    assert result.grant_revision == 3
    assert result.expires_at == @now + 100
    assert result.state == :host_authority_verification_required
    assert result.evidence == :unverified_host_assertions
    assert result.local_admission == :forbidden_until_authoritative_verification
    refute result.personal_membership
    refute result.financial_authority
  end

  test "natural person and unsupported business forms cannot become network members" do
    assert {:error, :business_not_eligible} =
             Participation.preflight(
               %{business() | business_kind: :individual},
               agent(),
               :publish_supply,
               @now
             )

    assert {:error, :business_not_eligible} =
             Participation.preflight(
               %{business() | business_id: @principal_id},
               agent(),
               :publish_supply,
               @now
             )

    assert {:error, :business_not_eligible} =
             Participation.preflight(%{}, agent(), :publish_supply, @now)
  end

  test "agent cannot act for another entity or escalate operation scope" do
    assert {:error, :agent_not_authorized} =
             Participation.preflight(
               business(),
               %{agent() | business_id: "https://another.example/entities/co"},
               :publish_supply,
               @now
             )

    assert {:error, :agent_not_authorized} =
             Participation.preflight(business(), agent(), :approve_clearing, @now)

    assert {:error, :agent_not_authorized} =
             Participation.preflight(
               business(),
               %{agent() | scopes: [:publish_supply, :publish_supply]},
               :publish_supply,
               @now
             )
  end

  test "revoked or expired business or agency snapshots refuse preflight" do
    assert {:error, :business_not_eligible} =
             Participation.preflight(
               %{business() | registration_state: :revoked},
               agent(),
               :publish_supply,
               @now
             )

    assert {:error, :business_not_eligible} =
             Participation.preflight(
               %{business() | registration_valid_until: @now},
               agent(),
               :publish_supply,
               @now
             )

    assert {:error, :business_not_eligible} =
             Participation.preflight(
               %{business() | sanctions_state: :blocked},
               agent(),
               :publish_supply,
               @now
             )

    assert {:error, :agent_not_authorized} =
             Participation.preflight(
               business(),
               %{agent() | grant_state: :revoked},
               :publish_supply,
               @now
             )

    assert {:error, :agent_not_authorized} =
             Participation.preflight(
               business(),
               %{agent() | expires_at: @now},
               :publish_supply,
               @now
             )
  end

  test "cross-border fulfillment stays on hold and money substitutes are unsupported" do
    assert {:ok, result} =
             Participation.preflight(
               business(),
               agent(),
               :cross_border_reciprocal_fulfillment,
               @now
             )

    assert result.state == :held_for_independent_cross_border_classification
    assert result.local_admission == :forbidden_until_authoritative_verification

    for capability <- [
          :send_money,
          :cash_payout,
          :issue_transferable_credit,
          :instruct_third_party_value_transfer
        ] do
      assert {:error, :financial_capability_not_supported} =
               Participation.preflight(business(), agent(), capability, @now)
    end
  end

  test "malformed evidence, unsolicited fields and invalid time fail closed" do
    assert {:error, :business_not_eligible} =
             Participation.preflight(
               Map.put(business(), :secret, "unexpected"),
               agent(),
               :publish_supply,
               @now
             )

    assert {:error, :agent_not_authorized} =
             Participation.preflight(
               business(),
               %{agent() | grant_revision: 0},
               :publish_supply,
               @now
             )

    assert {:error, :agent_not_authorized} =
             Participation.preflight(
               business(),
               %{agent() | principal_id: "person-account"},
               :publish_supply,
               @now
             )

    assert {:error, :unsupported_scope} =
             Participation.preflight(business(), agent(), :anything_else, @now)

    assert {:error, :invalid_preflight_request} =
             Participation.preflight(business(), agent(), :publish_supply, -1)
  end
end
