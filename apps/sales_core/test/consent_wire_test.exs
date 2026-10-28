defmodule SalesCore.ConsentWireTest do
  use ExUnit.Case, async: true

  alias SalesCore.{Consent, ConsentWire}

  @trusted %{
    tenant: "restaurant",
    party_ref: "customer-1",
    at_ms: 10,
    authorized_operations: [:grant, :withdraw],
    verified_evidence_ref: "receipt-1"
  }

  defp body(op, extra \\ %{}) do
    Map.merge(
      %{
        "schema" => "bizkit.sales.consent.v1",
        "tenant" => "restaurant",
        "party_ref" => "customer-1",
        "op" => op,
        "id" => "consent-1",
        "expected_version" => 0,
        "channel" => "telegram",
        "jurisdiction" => "CL"
      },
      extra
    )
  end

  test "an evidence-bound grant becomes a pure consent decision" do
    wire = body("grant", %{"audience" => "customer", "evidence_ref" => "receipt-1"})
    assert {:ok, event} = ConsentWire.decode(wire, @trusted)
    assert event.op == :grant
    assert event.channel == :telegram
    assert event.audience == :customer
    assert event.at_ms == 10

    {:ok, state} = Consent.new("restaurant")
    assert {:ok, next, :accepted} = Consent.record(state, "restaurant", event)
    assert Consent.allowed?(next, "restaurant", "customer-1", :telegram, "CL", :customer)
  end

  test "a party-verified withdrawal never needs a promotional evidence claim" do
    trusted = %{@trusted | at_ms: 12, authorized_operations: [:withdraw]}
    wire = body("withdraw", %{"id" => "withdraw-1"})
    assert {:ok, %{op: :withdraw, at_ms: 12}} = ConsentWire.decode(wire, trusted)

    assert {:error, :invalid_consent_shape} =
             ConsentWire.decode(Map.put(wire, "audience", "customer"), trusted)
  end

  test "client-supplied authority, time, addresses and unknown fields are refused" do
    wire = body("grant", %{"audience" => "customer", "evidence_ref" => "receipt-1"})

    for {key, value} <- [
          {"at_ms", 999},
          {"authorized_operations", ["grant"]},
          {"actor", "admin"},
          {"address", "private-contact"},
          {"approved", true}
        ] do
      assert {:error, :invalid_consent_shape} =
               ConsentWire.decode(Map.put(wire, key, value), @trusted)
    end
  end

  test "foreign merchant, party and unverified evidence cannot be accepted" do
    wire = body("grant", %{"audience" => "business_contact", "evidence_ref" => "receipt-1"})

    assert {:error, :wrong_consent_scope} =
             ConsentWire.decode(%{wire | "tenant" => "other"}, @trusted)

    assert {:error, :wrong_consent_scope} =
             ConsentWire.decode(%{wire | "party_ref" => "other"}, @trusted)

    assert {:error, :consent_evidence_not_verified} =
             ConsentWire.decode(%{wire | "evidence_ref" => "stolen"}, @trusted)

    assert {:error, :consent_operation_not_authorized} =
             ConsentWire.decode(wire, %{@trusted | authorized_operations: [:withdraw]})
  end

  test "learner, guardian and driver role labels never become promotional audiences" do
    for audience <- ~w(learner guardian driver employee) do
      wire = body("grant", %{"audience" => audience, "evidence_ref" => "receipt-1"})

      assert {:error, :unsupported_consent_classification} =
               ConsentWire.decode(wire, @trusted)
    end
  end

  test "channel and version shape errors fail closed without atom creation" do
    wire = body("grant", %{"audience" => "customer", "evidence_ref" => "receipt-1"})

    assert {:error, :unsupported_consent_classification} =
             ConsentWire.decode(%{wire | "channel" => "unrecognized"}, @trusted)

    assert {:error, :invalid_consent_version_or_time} =
             ConsentWire.decode(%{wire | "expected_version" => 1.5}, @trusted)

    assert {:error, :invalid_consent_version_or_time} =
             ConsentWire.decode(wire, %{@trusted | at_ms: -1})

    assert {:error, :unknown_consent_operation} =
             ConsentWire.decode(%{wire | "op" => "send"}, @trusted)

    assert {:error, :invalid_consent_shape} =
             ConsentWire.decode(%{wire | "schema" => "bizkit.sales.consent.v2"}, @trusted)
  end
end
