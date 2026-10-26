defmodule GroupBuyCore.EscrowProofTest do
  use ExUnit.Case, async: true

  alias GroupBuyCore.{BindingRound, Escrow, EscrowProof}

  @now 1_800_000_000
  @provider "test-authorized-custodian"
  @key_id "test-rotation-1"

  defp offer do
    %{
      id: "https://seller.example/group-buys/parts",
      seller: "https://seller.example/actors/merchant",
      sku: "parts",
      unit: "piece",
      currency: "USD",
      revision: 4,
      expires_at: @now + 900,
      capacity: 10,
      solo_unit_minor: 10_000,
      tiers: [%{min_quantity: 5, unit_minor: 9_000}]
    }
  end

  defp buyer(name), do: "https://#{name}.example/actors/buyer"

  defp pledge(name, quantity) do
    %{
      id: "https://#{name}.example/pledge/1",
      buyer: buyer(name),
      offer_id: offer().id,
      offer_revision: 4,
      quantity: quantity,
      max_group_unit_minor: 9_000,
      expires_at: @now + 600
    }
  end

  defp admit(state, name, quantity) do
    cmd = %{
      id: "admission-#{name}",
      expected_version: state.version,
      op: :pledge,
      pledge: pledge(name, quantity),
      evidence_ref: "seller-host-authenticates-upfront-conditional-contract"
    }

    {:ok, next, :accepted} = BindingRound.apply(state, buyer(name), cmd, @now)
    next
  end

  defp round do
    {:ok, initial} = BindingRound.new(offer(), @now)
    initial |> admit("a", 2) |> admit("b", 3)
  end

  defp grant(public_key) do
    %{
      provider_id: @provider,
      key_id: @key_id,
      public_key: public_key,
      active: true,
      grant_expires_at: @now + 10_000,
      campaign_id: offer().id,
      seller: offer().seller
    }
  end

  defp signing_keys, do: :crypto.generate_key(:eddsa, :ed25519)

  defp report(payload, private_key, overrides \\ %{}) do
    unsigned =
      Map.merge(
        %{
          schema: "bizkit.group-buy.provider-proof.v1",
          provider_id: @provider,
          key_id: @key_id,
          campaign_id: offer().id,
          seller: offer().seller,
          offer_revision: offer().revision,
          issued_at: @now,
          expires_at: @now + 900,
          event_ref: "provider-report-1",
          payload: payload,
          signature: <<0::512>>
        },
        overrides
      )

    {:ok, message} = EscrowProof.signing_payload(unsigned)
    %{unsigned | signature: :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])}
  end

  defp funding(name, quantity) do
    %{
      op: :hold_confirmed,
      buyer: buyer(name),
      pledge_id: pledge(name, quantity).id,
      custody_ref: "provider-held-#{name}",
      currency: "USD",
      amount_minor: quantity * 9_000,
      expires_at: @now + 2_000
    }
  end

  test "signed custodian report produces only an unsigned seller-home admission candidate" do
    {public, private} = signing_keys()
    bound = round()
    {:ok, escrow} = Escrow.new(offer(), @now)

    a = report(funding("a", 2), private)
    assert {:ok, prepared} = EscrowProof.preview(escrow, bound, a, grant(public), @now)
    assert prepared.kind == :verified_provider_event_candidate
    refute prepared.authoritative
    assert prepared.requires == :seller_home_signed_ledger_commit
    assert prepared.producer == {:custody_provider, @provider}
    assert prepared.command.op == :hold_confirmed
    assert prepared.command.amount_minor == 18_000
    assert byte_size(prepared.command.id) == 64
    assert byte_size(prepared.provider_proof_hash) == 64

    escrow = prepared.escrow_projection
    assert escrow.positions[buyer("a")].status == :held
    assert {:error, :escrow_coverage_incomplete} = Escrow.coverage(escrow, bound, @now)

    b = report(funding("b", 3), private, %{event_ref: "provider-report-2"})
    assert {:ok, second} = EscrowProof.preview(escrow, bound, b, grant(public), @now)
    assert second.command.amount_minor == 27_000
    assert {:ok, coverage} = Escrow.coverage(second.escrow_projection, bound, @now)
    assert coverage.secured_minor == 45_000
    assert coverage.current_group_due_minor == 45_000

    assert {:ok, duplicate} =
             EscrowProof.preview(second.escrow_projection, bound, b, grant(public), @now)

    assert duplicate.disposition == :duplicate
    assert duplicate.escrow_projection == second.escrow_projection
  end

  test "report tampering, bad signing key and untrusted provider grants refuse" do
    {public, private} = signing_keys()
    {different_public, _} = signing_keys()
    bound = round()
    {:ok, escrow} = Escrow.new(offer(), @now)
    signed = report(funding("a", 2), private)

    assert {:error, :invalid_provider_signature} =
             EscrowProof.preview(
               escrow,
               bound,
               %{signed | payload: %{signed.payload | amount_minor: 18_001}},
               grant(public),
               @now
             )

    assert {:error, :invalid_provider_signature} =
             EscrowProof.preview(escrow, bound, signed, grant(different_public), @now)

    assert {:error, :untrusted_provider_grant} =
             EscrowProof.preview(
               escrow,
               bound,
               signed,
               %{grant(public) | active: false},
               @now
             )

    assert {:error, :invalid_provider_proof} =
             EscrowProof.preview(
               escrow,
               bound,
               Map.put(signed, :untrusted_bank_account, "private"),
               grant(public),
               @now
             )
  end

  test "campaign/seller revision, key identity and time are signed and scoped" do
    {public, private} = signing_keys()
    bound = round()
    {:ok, escrow} = Escrow.new(offer(), @now)
    base = funding("a", 2)

    for patch <- [
          %{campaign_id: "https://different.example/group-buys/parts"},
          %{seller: "https://imposter.example/actors/seller"},
          %{key_id: "rotated-without-grant"},
          %{offer_revision: 7}
        ] do
      signed = report(base, private, patch)

      assert {:error, :provider_proof_out_of_scope_or_stale} =
               EscrowProof.preview(escrow, bound, signed, grant(public), @now)
    end

    signed = report(base, private, %{issued_at: @now - 700})
    assert {:error, :provider_proof_out_of_scope_or_stale} =
             EscrowProof.preview(escrow, bound, signed, grant(public), @now)

    signed = report(base, private, %{issued_at: @now + 1})
    assert {:error, :provider_proof_out_of_scope_or_stale} =
             EscrowProof.preview(escrow, bound, signed, grant(public), @now)
  end

  test "provider report reference is stable across changed payload and cannot double-count" do
    {public, private} = signing_keys()
    bound = round()
    {:ok, escrow} = Escrow.new(offer(), @now)
    original = report(funding("a", 2), private)
    {:ok, first} = EscrowProof.preview(escrow, bound, original, grant(public), @now)

    # A second VALID signature reusing the same provider event identity
    # cannot be independently admitted as another financial fact.
    changed =
      report(
        funding("a", 2),
        private,
        %{issued_at: @now + 1, event_ref: original.event_ref}
      )

    assert {:error, :idempotency_conflict} =
             EscrowProof.preview(
               first.escrow_projection,
               bound,
               changed,
               grant(public),
               @now + 1
             )
  end

  test "provider-signed settlement still requires group coverage and delivery conditions" do
    {public, private} = signing_keys()
    bound = round()
    {:ok, escrow} = Escrow.new(offer(), @now)

    release_payload = %{
      op: :delivery_release_confirmed,
      buyer: buyer("a"),
      custody_ref: "provider-held-a",
      settlement_ref: "payment-confirmation-1",
      delivery_proof_ref: "provider-confirmed-delivery-proof",
      seller_paid_minor: 18_000,
      buyer_refund_minor: 0
    }

    proof = report(release_payload, private, %{event_ref: "seller-payment-1"})
    assert {:error, :release_requires_binding_funding_and_verified_delivery} =
             EscrowProof.preview(escrow, bound, proof, grant(public), @now)

    {:ok, funded_a} =
      EscrowProof.preview(escrow, bound, report(funding("a", 2), private), grant(public), @now)

    {:ok, funded_b} =
      EscrowProof.preview(
        funded_a.escrow_projection,
        bound,
        report(funding("b", 3), private, %{event_ref: "fund-b"}),
        grant(public),
        @now
      )

    assert {:ok, paid} =
             EscrowProof.preview(
               funded_b.escrow_projection,
               bound,
               proof,
               grant(public),
               @now
             )

    assert paid.escrow_projection.positions[buyer("a")].status == :released
    assert paid.escrow_projection.positions[buyer("a")].disposition.seller_minor == 18_000
  end

  test "only specifically shaped provider financial events are signable" do
    {_public, private} = signing_keys()

    for payload <- [
          Map.put(funding("a", 2), :bank_secret, "bad"),
          %{op: :release_money_now},
          %{op: :hold_confirmed, buyer: buyer("a")},
          %{funding("a", 2) | amount_minor: 3.25}
        ] do
      malformed = %{
        schema: "bizkit.group-buy.provider-proof.v1",
        provider_id: @provider,
        key_id: @key_id,
        campaign_id: offer().id,
        seller: offer().seller,
        offer_revision: 4,
        issued_at: @now,
        expires_at: @now + 500,
        event_ref: "malformed",
        payload: payload,
        signature: <<0::512>>
      }

      assert {:error, :invalid_provider_proof} = EscrowProof.signing_payload(malformed)
    end

    # The provider cannot authorize a buyer's business withdrawal/dispute
    # by signing a custody report. Those actions use other host authorities.
    assert {:error, :invalid_provider_proof} =
             EscrowProof.signing_payload(
               report(funding("a", 2), private)
               |> Map.put(:payload, %{op: :dispute_open, buyer: buyer("a")})
             )
  end
end
