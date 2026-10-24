defmodule SalesCoreTest do
  use ExUnit.Case, async: true

  alias SalesCore.{Campaign, Consent, Pipeline}

  defp change(state, id, op, fields) do
    Map.merge(%{id: id, expected_version: state.version, op: op}, fields)
  end

  defp grant(state, party, audience, id, timestamp) do
    change(state, id, :grant, %{
      party_ref: party,
      channel: :telegram,
      jurisdiction: "CL",
      audience: audience,
      evidence_ref: "consent-#{id}",
      at_ms: timestamp
    })
  end

  test "restaurant opt-in can be withdrawn; retry and stale regrant refuse" do
    {:ok, empty} = Consent.new("restaurant")
    event = grant(empty, "customer-1", :customer, "g1", 10)
    {:ok, state, :accepted} = Consent.record(empty, "restaurant", event)
    assert {:ok, state, :duplicate} = Consent.record(state, "restaurant", event)

    assert Consent.allowed?(
             state,
             "restaurant",
             "customer-1",
             :telegram,
             "CL",
             :customer
           )

    withdrawal =
      change(state, "w1", :withdraw, %{
        party_ref: "customer-1",
        channel: :telegram,
        jurisdiction: "CL",
        at_ms: 20
      })

    {:ok, state, :accepted} = Consent.record(state, "restaurant", withdrawal)

    refute Consent.allowed?(
             state,
             "restaurant",
             "customer-1",
             :telegram,
             "CL",
             :customer
           )

    stale = grant(state, "customer-1", :customer, "g2", 19)

    assert {:error, :stale_consent_evidence} =
             Consent.record(state, "restaurant", stale)

    refreshed = grant(state, "customer-1", :customer, "g3", 21)
    {:ok, state, :accepted} = Consent.record(state, "restaurant", refreshed)
    assert state.version == 3
  end

  test "guardian, learner, driver and employee roles confer no marketing grant" do
    {:ok, state} = Consent.new("school")

    for audience <- [:guardian, :learner, :driver, :employee] do
      assert {:error, :audience_or_evidence_not_authorized} =
               Consent.record(state, "school", grant(state, "p1", audience, "g", 1))
    end

    refute Consent.allowed?(state, "school", "p1", :telegram, "CL", :customer)
    refute Consent.allowed?(state, "school", "p1", :email, "CL", :customer)
  end

  test "broker business contacts require explicit scope and grant; never infer all channels" do
    {:ok, state} = Consent.new("logistics")
    event = grant(state, "broker-1", :business_contact, "g1", 10)
    {:ok, state, :accepted} = Consent.record(state, "logistics", event)

    assert Consent.allowed?(
             state,
             "logistics",
             "broker-1",
             :telegram,
             "CL",
             :business_contact
           )

    refute Consent.allowed?(
             state,
             "other",
             "broker-1",
             :telegram,
             "CL",
             :business_contact
           )

    refute Consent.allowed?(
             state,
             "logistics",
             "broker-1",
             :sms,
             "CL",
             :business_contact
           )

    assert {:error, :wrong_tenant} = Consent.record(state, "other", event)
  end

  test "campaign plan returns opaque, opted-in recipients without sending" do
    {:ok, state} = Consent.new("restaurant")

    {:ok, state, :accepted} =
      Consent.record(state, "restaurant", grant(state, "buyer-1", :customer, "g", 1))

    audience = [
      %{party_ref: "buyer-1", audience: :customer},
      %{party_ref: "buyer-2", audience: :customer},
      %{party_ref: "guardian-1", audience: :guardian},
      %{party_ref: "buyer-1", audience: :customer}
    ]

    assert {:ok, %{consent_version: 1, recipient_refs: ["buyer-1"]}} =
             Campaign.plan(state, "restaurant", :telegram, "CL", audience)

    assert {:error, :wrong_tenant} =
             Campaign.plan(state, "school", :telegram, "CL", audience)
  end

  test "sales stages use shared, tenant-scoped quote references, not task completion" do
    {:ok, state} = Pipeline.new("merchant")

    {:ok, state} =
      Pipeline.create(state, "merchant", 0, %{
        id: "lead-1",
        party_ref: "contact-1",
        source: "inbound"
      })

    assert {:error, :invalid_pipeline_transition} =
             Pipeline.advance(state, "merchant", 1, "lead-1", :won)

    {:ok, state} = Pipeline.advance(state, "merchant", 1, "lead-1", :qualified)
    {:ok, state} = Pipeline.advance(state, "merchant", 2, "lead-1", :proposed)

    assert {:error, :invalid_reference} =
             Pipeline.advance(state, "merchant", 3, "lead-1", :won)

    {:ok, state} = Pipeline.advance(state, "merchant", 3, "lead-1", :won, "quote-1")

    assert {:ok, %{state: :won, quote_ref: "quote-1"}} =
             Pipeline.fetch(state, "merchant", "lead-1")

    assert {:error, :stale_pipeline_version} =
             Pipeline.advance(state, "merchant", 3, "lead-1", :lost)

    assert {:error, :wrong_tenant} =
             Pipeline.fetch(state, "other", "lead-1")
  end

  test "unknown contact is suppressed; a recorded withdrawal survives replay" do
    {:ok, empty} = Consent.new("merchant")

    event =
      change(empty, "w", :withdraw, %{
        party_ref: "not-yet-known",
        channel: :email,
        jurisdiction: "US",
        at_ms: 1
      })

    {:ok, state} = Consent.replay(empty, "merchant", [event])
    refute Consent.allowed?(state, "merchant", "not-yet-known", :email, "US", :customer)

    assert {:error, :stale_consent_version} =
             Consent.record(state, "merchant", %{event | id: "another"})
  end
end
