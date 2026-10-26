defmodule CoopSubstrate.GroupBuyEscrowAdmissionTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{Canonical, GroupBuys, Log}
  alias CoopSubstrate.Projections.Membership
  alias GroupBuyCore.{Escrow, EscrowProof}

  @chapter "chapter-genesis"
  @seller "https://seller.example/actors/seller"
  @buyer "https://buyer.example/actors/buyer"
  @campaign "https://seller.example/group-buys/escrow"
  @provider "custodian-one"

  setup do
    now = System.system_time(:second)
    gov = new_member("governance")
    seller = new_member("group_seller")
    buyer = new_member("group_buyer")
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    {:ok, _} =
      GroupBuys.submit(
        signed_event(gov, "GroupBuySellerAuthorizedV1", %{
          "seller_id" => @seller,
          "key_id" => seller.signer.key_id,
          "pubkey" => {:bytes, seller.signer.pubkey},
          "expires_at" => now + 3600,
          "expected_version" => 0
        })
      )

    member_signer = %{buyer | signer: %{buyer.signer | role: "member"}}

    {:ok, _} =
      Log.append(
        signed_event(member_signer, "MemberRegistered", %{
          "member_id" => @buyer,
          "pubkey" => {:bytes, buyer.signer.pubkey},
          "key_id" => buyer.signer.key_id
        })
      )

    {:ok, _} =
      GroupBuys.submit(
        signed_event(seller, "GroupBuyMemberAuthorizedV1", %{
          "seller_id" => @seller,
          "buyer_id" => @buyer,
          "key_id" => buyer.signer.key_id,
          "pubkey" => {:bytes, buyer.signer.pubkey},
          "expires_at" => now + 1800,
          "expected_version" => 0,
          "active" => true
        })
      )

    offer = posted_offer(seller, @campaign, now)
    {:ok, _} = GroupBuys.submit(offer)
    {:ok, offer_hash} = GroupBuys.terms_hash(offer)

    ctx = %{
      seller: seller,
      buyer: buyer,
      now: now,
      provider_public: pub,
      provider_private: priv,
      offer_hash: offer_hash
    }

    {:ok, ctx}
  end

  defp posted_offer(seller, campaign, now) do
    signed_event(seller, "GroupBuyOfferPostedV1", %{
      "seller_id" => @seller,
      "campaign_id" => campaign,
      "policy" => GroupBuys.policy(),
      "offer" => %{
        "id" => campaign,
        "seller" => @seller,
        "sku" => "parts",
        "unit" => "piece",
        "currency" => "USD",
        "revision" => 3,
        "expires_at" => now + 600,
        "capacity" => 10,
        "solo_unit_minor" => 10_000,
        "tiers" => [%{"min_quantity" => 5, "unit_minor" => 9_000}]
      }
    })
  end

  defp bind(ctx, campaign \\ @campaign, offer_hash \\ nil) do
    hash = offer_hash || ctx.offer_hash
    now = System.system_time(:second)

    buyer_consent =
      signed_event(ctx.buyer, "GroupBuyConsentV1", %{
        "seller_id" => @seller,
        "campaign_id" => campaign,
        "buyer_id" => @buyer,
        "terms_hash" => {:bytes, hash},
        "policy" => GroupBuys.policy(),
        "valid_until" => now + 120,
        "command" => %{
          "op" => "pledge",
          "expected_version" => 0,
          "pledge" => %{
            "id" => @buyer <> "/pledge/escrow",
            "buyer" => @buyer,
            "offer_id" => campaign,
            "offer_revision" => 3,
            "quantity" => 5,
            "max_group_unit_minor" => 9_000,
            "expires_at" => now + 120
          }
        }
      })

    {:ok, admitted} = GroupBuys.acceptance(buyer_consent, ctx.seller.signer)
    {:ok, admitted} =
      CoopSubstrate.Protocol.Envelope.sign(
        admitted,
        ctx.seller.signer.key_id,
        ctx.seller.seed
      )

    assert {:ok, _} = GroupBuys.submit(admitted)
  end

  defp pin(ctx, campaign \\ @campaign, version \\ 0, provider_id \\ @provider) do
    signed_event(ctx.seller, "GroupBuyEscrowProviderPinnedV1", %{
      "seller_id" => @seller,
      "campaign_id" => campaign,
      "provider_id" => provider_id,
      "key_id" => "provider-signing-1",
      "pubkey" => {:bytes, ctx.provider_public},
      "active" => true,
      "expires_at" => ctx.now + 2400,
      "expected_version" => version
    })
  end

  defp provider_report(ctx, campaign \\ @campaign, changes \\ %{}) do
    issued_at = System.system_time(:second)

    raw =
      %{
        schema: "bizkit.group-buy.provider-proof.v1",
        provider_id: @provider,
        key_id: "provider-signing-1",
        campaign_id: campaign,
        seller: @seller,
        offer_revision: 3,
        issued_at: issued_at,
        expires_at: issued_at + 300,
        event_ref: "funding-confirmation",
        payload: %{
          op: :hold_confirmed,
          buyer: @buyer,
          pledge_id: @buyer <> "/pledge/escrow",
          custody_ref: "escrow-allocation-1",
          currency: "USD",
          amount_minor: 45_000,
          expires_at: ctx.now + 3000
        },
        signature: <<0::512>>
      }
      |> Map.merge(changes)

    {:ok, message} = EscrowProof.signing_payload(raw)
    %{raw | signature: :crypto.sign(:eddsa, :none, message, [ctx.provider_private, :ed25519])}
  end

  defp encode_report(proof) do
    attrs =
      proof
      |> Map.delete(:signature)
      |> Map.new(fn
        {:payload, p} ->
          {"payload",
           Map.new(p, fn
             {:op, atom} -> {"op", Atom.to_string(atom)}
             {:reason, atom} -> {"reason", Atom.to_string(atom)}
             {key, value} -> {Atom.to_string(key), value}
           end)}

        {key, value} ->
          {Atom.to_string(key), value}
      end)
      |> Map.put("signature", {:bytes, proof.signature})

    Canonical.encode!(attrs)
  end

  defp evidence(ctx, proof, campaign \\ @campaign, version \\ 0) do
    signed_event(ctx.seller, "GroupBuyEscrowEvidenceAdmittedV1", %{
      "seller_id" => @seller,
      "campaign_id" => campaign,
      "proof" => {:bytes, encode_report(proof)},
      "expected_version" => version
    })
  end

  defp rejected(event, reason) do
    before = Log.head()
    assert {:error, {:reject, 0, ^reason}} = GroupBuys.submit(event)
    assert Log.head() == before
  end

  test "seller-home signed provider report enters the ONE canonical ledger with durable recovery",
       ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    bind(ctx)
    proof = provider_report(ctx)
    provider_event = evidence(ctx, proof)

    assert {:ok, receipt} = GroupBuys.submit(provider_event)
    assert receipt.payment == :not_collected
    assert receipt.inventory == :not_reserved

    key = {@chapter, @seller, @campaign}
    gate = Log.gate()
    row = gate.group_buys.escrow_states[key]
    assert row.version == 1
    assert row.positions[@buyer].status == :held

    assert gate.group_buys.escrow_custody_claims[{@provider, "escrow-allocation-1"}] ==
             %{campaign_key: key, buyer: @buyer}

    assert {:ok, cover} = Escrow.coverage(row, gate.group_buys.rounds[key], ctx.now)
    assert cover.secured_minor == 45_000
    assert cover.current_group_due_minor == 45_000

    assert :ok = Log.verify_chains()
    restart_log()
    assert Log.gate().group_buys.escrow_states[key] == row
    assert {:ok, replayed} = Log.replay(Membership)
    assert replayed.group_buys == Log.gate().group_buys
  end

  test "no unsigned, forged-key, stale or duplicate external report can enter the ledger", ctx do
    bind(ctx)
    proof = provider_report(ctx)
    rejected(evidence(ctx, proof), :invalid_escrow_evidence_admission)

    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    other = %{proof | payload: %{proof.payload | amount_minor: 40_000}}
    rejected(evidence(ctx, other), :invalid_provider_signature)

    assert {:ok, _} = GroupBuys.submit(evidence(ctx, proof))

    # Another distinct seller envelope with the *same provider event ID*
    # cannot count that protected money twice.
    rejected(evidence(ctx, proof, @campaign, 1), :provider_event_already_admitted)

    # Same provider/campaign/event_ref re-signed with conflicting facts
    # must be refused globally, not merely by the local escrow reducer.
    replaced = provider_report(ctx, @campaign, %{event_ref: proof.event_ref})
    rejected(evidence(ctx, replaced, @campaign, 1), :provider_event_already_admitted)
  end

  test "one provider custody allocation cannot secure a different campaign", ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))

    campaign2 = @campaign <> "-second"
    offer2 = posted_offer(ctx.seller, campaign2, ctx.now)
    assert {:ok, _} = GroupBuys.submit(offer2)
    {:ok, hash2} = GroupBuys.terms_hash(offer2)

    assert {:ok, _} = GroupBuys.submit(pin(ctx, campaign2))
    bind(ctx, campaign2, hash2)

    reused =
      provider_report(ctx, campaign2, %{
        event_ref: "new-provider-event-but-same-custody"
      })

    rejected(evidence(ctx, reused, campaign2), :cross_campaign_custody_reused)
  end
end
