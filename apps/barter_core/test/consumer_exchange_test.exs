defmodule BarterCore.ConsumerExchangeTest do
  use ExUnit.Case, async: true

  alias BarterCore.ConsumerExchange, as: Exchange

  @now 1_800_000_000
  @alice "prn_" <> String.duplicate("a", 26)
  @bob "prn_" <> String.duplicate("b", 26)
  @agent "prn_" <> String.duplicate("c", 26)
  @business "https://merchant.example/entities/consignment-shop"

  defp person(id, country \\ "US") do
    %{
      kind: :individual,
      principal_id: id,
      verification: :current,
      age_status: :adult,
      country: country,
      expires_at: @now + 500
    }
  end

  defp business(country \\ "US") do
    %{
      kind: :business,
      business_id: @business,
      verification: :current,
      country: country,
      expires_at: @now + 500
    }
  end

  defp broker(country \\ "US") do
    %{
      business: business(country),
      agent: %{
        principal_id: @agent,
        business_id: @business,
        grant_ref: "https://merchant.example/grants/consignment-agent",
        grant_revision: 3,
        grant_state: :active,
        scopes: [:consignment_intermediation],
        expires_at: @now + 100
      },
      seller_consent_ref: "https://merchant.example/consents/seller-1",
      seller_consent_revision: 2,
      terms_hash: String.duplicate("f", 64),
      expires_at: @now + 100
    }
  end

  defp trade do
    %{
      mode: :direct_p2p,
      seller: person(@alice),
      buyer: person(@bob),
      broker: nil,
      offer_ref: "https://consumer.example/offers/bicycle",
      offer_revision: 1,
      want_ref: "https://consumer.example/offers/furniture",
      want_revision: 1,
      consideration: :specified_in_kind_exchange,
      expires_at: @now + 50
    }
  end

  defp consignment do
    %{trade() | mode: :business_consignment, broker: broker()}
  end

  test "adult peer-to-peer barter only creates an inert domestic preview" do
    assert {:ok, preview} = Exchange.preview(trade(), @now)
    assert preview.mode == :direct_p2p
    assert preview.country_scope == :domestic_candidate
    assert preview.decision == :requires_independent_host_admission
    assert preview.status == :unadmitted_preview_only
    assert preview.evidence == :caller_asserted_unverified
    refute preview.inventory_reserved
    refute preview.title_transfer
    refute preview.legal_consent_verified
    refute preview.consumer_credit_issued
    refute preview.payment_or_value_transfer
    refute preview.business_clearing_authority
  end

  test "direct peer-to-peer rejects business counterparties and broker inserts" do
    assert {:error, :ineligible_counterparty} =
             Exchange.preview(%{trade() | buyer: business()}, @now)

    assert {:error, :invalid_intermediation} =
             Exchange.preview(%{trade() | broker: broker()}, @now)
  end

  test "consignment requires a business and its expressly scoped agent" do
    assert {:ok, result} = Exchange.preview(consignment(), @now)
    assert result.mode == :business_consignment
    assert result.decision == :requires_independent_host_admission

    assert {:ok, _} =
             Exchange.preview(%{consignment() | buyer: business()}, @now)

    assert {:error, :invalid_intermediation} =
             Exchange.preview(%{consignment() | broker: nil}, @now)

    assert {:error, :unverified_intermediary} =
             Exchange.preview(
               %{consignment() | broker: %{broker() | agent: %{broker().agent | grant_state: :revoked}}},
               @now
             )
  end

  test "unscoped, mismatched and expired business agents fail closed" do
    bad_grant = %{broker().agent | business_id: "https://other.example/entities/shop"}
    bad_scopes = %{broker().agent | scopes: [:approve_clearing]}
    expired = %{broker().agent | expires_at: @now}

    for changed <- [bad_grant, bad_scopes, expired] do
      assert {:error, :unverified_intermediary} =
               Exchange.preview(%{consignment() | broker: %{broker() | agent: changed}}, @now)
    end
  end

  test "an individual must be distinct, adult and current" do
    assert {:error, :ineligible_counterparty} =
             Exchange.preview(%{trade() | buyer: person(@alice)}, @now)

    assert {:error, :ineligible_counterparty} =
             Exchange.preview(
               %{trade() | seller: %{person(@alice) | age_status: :minor}},
               @now
             )

    assert {:error, :ineligible_counterparty} =
             Exchange.preview(
               %{trade() | buyer: %{person(@bob) | verification: :revoked}},
               @now
             )

    assert {:error, :ineligible_counterparty} =
             Exchange.preview(
               %{trade() | seller: %{person(@alice) | expires_at: @now}},
               @now
             )
  end

  test "foreign peer or intermediary is HOLD, never admitted or authorized" do
    assert {:ok, p2p} =
             Exchange.preview(%{trade() | buyer: person(@bob, "PK")}, @now)

    assert p2p.country_scope == :cross_border
    assert p2p.decision == :held_for_cross_border_classification

    assert {:ok, mediated} =
             Exchange.preview(%{consignment() | broker: broker("PK")}, @now)

    assert mediated.country_scope == :cross_border
    assert mediated.decision == :held_for_cross_border_classification
    refute mediated.payment_or_value_transfer
  end

  test "no money, transferable scrip, arbitrary third-party beneficiary or hidden fields" do
    assert {:error, :invalid_trade} =
             Exchange.preview(%{trade() | consideration: :cash_value_transfer}, @now)

    assert {:error, :invalid_trade} =
             Exchange.preview(%{trade() | consideration: :trade_credit}, @now)

    assert {:error, :invalid_trade} =
             Exchange.preview(Map.put(trade(), :designated_recipient, "third-party"), @now)

    assert {:error, :invalid_trade} =
             Exchange.preview(Map.put(trade(), :cash_payout, true), @now)
  end

  test "altered consignment consent, agent or listing revisions change digest" do
    assert {:ok, initial} = Exchange.preview(consignment(), @now)

    altered = [
      %{consignment() | offer_revision: 2},
      %{consignment() | want_revision: 2},
      %{consignment() | broker: %{broker() | seller_consent_revision: 3}},
      %{consignment() | broker: %{broker() | agent: %{broker().agent | grant_revision: 4}}},
      %{consignment() | broker: %{broker() | terms_hash: String.duplicate("a", 64)}}
    ]

    for t <- altered do
      assert {:ok, changed} = Exchange.preview(t, @now)
      refute changed.snapshot_digest == initial.snapshot_digest
    end
  end

  test "expiry, invalid source revision and malformed party fail closed" do
    assert {:error, :invalid_trade} =
             Exchange.preview(%{trade() | expires_at: @now}, @now)

    assert {:error, :invalid_trade} =
             Exchange.preview(%{trade() | offer_revision: 0}, @now)

    assert {:error, :invalid_trade} =
             Exchange.preview(%{trade() | offer_ref: "not a supported source"}, @now)

    assert {:error, :ineligible_counterparty} =
             Exchange.preview(%{trade() | buyer: Map.put(person(@bob), :phone, "private")}, @now)
  end
end
