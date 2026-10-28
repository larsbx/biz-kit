defmodule BizKit.MarketingBridgeTest do
  use ExUnit.Case, async: true

  alias BizKit.MarketingBridge
  alias SalesCore.Consent

  @delivered ~U[2026-10-28 12:00:00Z]
  @checkin ~U[2026-10-28 12:05:00Z]

  defp grant(state, id, event_ms) do
    %{
      id: id,
      expected_version: state.version,
      op: :grant,
      party_ref: "buyer-1",
      jurisdiction: "US",
      channel: :telegram,
      audience: :customer,
      evidence_ref: "consent-proof-" <> id,
      at_ms: event_ms
    }
  end

  defp consent do
    {:ok, empty} = Consent.new("restaurant")
    {:ok, state, :accepted} = Consent.record(empty, "restaurant", grant(empty, "g1", 1))
    state
  end

  defp receipt do
    %{
      tenant: "restaurant",
      party_ref: "buyer-1",
      campaign_id: "campaign-1",
      channel: :telegram,
      jurisdiction: "US",
      audience: :customer,
      delivery_status: :confirmed,
      delivery_receipt_id: "delivery-1",
      delivery_receipt_digest: "digest-1",
      delivered_at: @delivered
    }
  end

  defp trusted(state) do
    %{
      tenant: "restaurant",
      party_ref: "buyer-1",
      campaign_id: "campaign-1",
      consent_version: state.version,
      verified_delivery_receipt: %{id: "delivery-1", digest: "digest-1", body: receipt()}
    }
  end

  test "a current consent and verified delivery produce an attributed candidate only" do
    state = consent()
    receipt = receipt()

    assert {:ok, candidate} =
             MarketingBridge.preview(state, receipt, @checkin, 300, trusted(state))

    assert candidate.kind == :unsigned_attribution_candidate
    assert candidate.merchant == "restaurant"
    assert candidate.party_ref == "buyer-1"
    assert candidate.consent_version == 1
    assert candidate.delivery_receipt_digest == "digest-1"
    assert state.version == 1
  end

  test "different merchant, party, campaign and digest fail closed" do
    state = consent()
    scope = trusted(state)

    for tamper <- [
          %{tenant: "freight"},
          %{party_ref: "other"},
          %{campaign_id: "different"}
        ] do
      assert {:error, :wrong_attribution_scope} =
               MarketingBridge.preview(state, Map.merge(receipt(), tamper), @checkin, 300, scope)
    end

    assert {:error, :unverified_delivery_receipt} =
             MarketingBridge.preview(
               state,
               %{receipt() | delivery_receipt_digest: "forged"},
               @checkin,
               300,
               scope
             )

    assert {:error, :unverified_delivery_receipt} =
             MarketingBridge.preview(
               state,
               %{receipt() | delivery_status: :queued},
               @checkin,
               300,
               scope
             )

    for unverified_change <- [
          %{delivered_at: DateTime.add(@delivered, -120)},
          %{audience: :business_contact},
          %{jurisdiction: "CA"},
          %{channel: :sms},
          %{last_attributed_at: DateTime.add(@delivered, -1)}
        ] do
      assert {:error, :unverified_delivery_receipt} =
               MarketingBridge.preview(
                 state,
                 Map.merge(receipt(), unverified_change),
                 @checkin,
                 300,
                 scope
               )
    end
  end

  test "withdrawal suppresses previously delivered marketing and stale revisions" do
    state = consent()
    old = trusted(state)

    withdrawal = %{
      id: "w1",
      expected_version: state.version,
      op: :withdraw,
      party_ref: "buyer-1",
      jurisdiction: "US",
      channel: :telegram,
      at_ms: 2
    }

    {:ok, withdrawn, :accepted} = Consent.record(state, "restaurant", withdrawal)

    assert {:error, :stale_consent_version} =
             MarketingBridge.preview(withdrawn, receipt(), @checkin, 300, old)

    assert {:error, :no_current_marketing_consent} =
             MarketingBridge.preview(withdrawn, receipt(), @checkin, 300, trusted(withdrawn))
  end

  test "no consent, wrong channel and late or early check-in cannot be attributed" do
    {:ok, empty} = Consent.new("restaurant")

    assert {:error, :no_current_marketing_consent} =
             MarketingBridge.preview(empty, receipt(), @checkin, 300, trusted(empty))

    state = consent()

    signed_sms = %{receipt() | channel: :sms}
    signed_context = put_in(trusted(state), [:verified_delivery_receipt, :body], signed_sms)

    assert {:error, :no_current_marketing_consent} =
             MarketingBridge.preview(state, signed_sms, @checkin, 300, signed_context)

    assert {:error, :not_attributable} =
             MarketingBridge.preview(
               state,
               receipt(),
               DateTime.add(@checkin, 1, :microsecond),
               300,
               trusted(state)
             )

    assert {:error, :not_attributable} =
             MarketingBridge.preview(
               state,
               receipt(),
               DateTime.add(@delivered, -1, :microsecond),
               300,
               trusted(state)
             )
  end
end
