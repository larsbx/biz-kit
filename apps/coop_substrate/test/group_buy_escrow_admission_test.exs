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
      gov: gov,
      seller: seller,
      buyer: buyer,
      now: now,
      provider_public: pub,
      provider_private: priv,
      offer_hash: offer_hash
    }

    authority = provider_authority(ctx)
    assert {:ok, _} = GroupBuys.submit(authority)
    {:ok, Map.put(ctx, :authority_id, authority.event_id)}
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
    assert {:ok, _} = GroupBuys.submit(contract(ctx, campaign, offer_hash))
  end

  defp contract(ctx, campaign \\ @campaign, offer_hash \\ nil) do
    buyer_id = Map.get(ctx, :buyer_id, @buyer)
    hash = offer_hash || ctx.offer_hash
    now = System.system_time(:second)

    buyer_consent =
      signed_event(ctx.buyer, "GroupBuyConsentV1", %{
        "seller_id" => @seller,
        "campaign_id" => campaign,
        "buyer_id" => buyer_id,
        "terms_hash" => {:bytes, hash},
        "policy" => GroupBuys.policy(),
        "valid_until" => now + 120,
        "command" => %{
          "op" => "pledge",
          "expected_version" => Map.get(ctx, :round_version, 0),
          "pledge" => %{
            "id" => buyer_id <> "/pledge/escrow",
            "buyer" => buyer_id,
            "offer_id" => campaign,
            "offer_revision" => 3,
            "quantity" => Map.get(ctx, :quantity, 5),
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

    admitted
  end

  defp pin(ctx, campaign \\ @campaign, version \\ 0, provider_id \\ @provider) do
    signed_event(ctx.seller, "GroupBuyEscrowProviderPinnedV2", %{
      "seller_id" => @seller,
      "campaign_id" => campaign,
      "provider_id" => provider_id,
      "authority_event_id" => ctx.authority_id,
      "expires_at" => ctx.now + 2400,
      "expected_version" => version
    })
  end

  defp provider_authority(ctx, changes \\ %{}) do
    signed_event(
      ctx.gov,
      "GroupBuyEscrowProviderAuthorizedV1",
      Map.merge(
        %{
          "provider_id" => @provider,
          "key_id" => "provider-signing-1",
          "pubkey" => {:bytes, ctx.provider_public},
          "active" => true,
          "expires_at" => ctx.now + 3600,
          "expected_version" => 0,
          "provenance_ref" => "fixture-only/independent-provider-review",
          "provenance_hash" => {:bytes, :crypto.hash(:sha256, "test-only credential review")}
        },
        changes
      )
    )
  end

  defp provider_report(ctx, campaign \\ @campaign, changes \\ %{}) do
    buyer_id = Map.get(ctx, :buyer_id, @buyer)
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
        event_ref: "funding-confirmation/" <> buyer_id,
        payload: %{
          op: :hold_confirmed,
          buyer: buyer_id,
          pledge_id: buyer_id <> "/pledge/escrow",
          custody_ref: Map.get(ctx, :custody_ref, "escrow-allocation-1"),
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
             %{campaign_key: key, buyer: @buyer, authority_event_id: ctx.authority_id}

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
    rejected(evidence(ctx, proof), :authenticated_provider_pin_required)

    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    other = %{proof | payload: %{proof.payload | amount_minor: 40_000}}
    rejected(evidence(ctx, other), :invalid_provider_signature)

    assert {:ok, _} = GroupBuys.submit(evidence(ctx, proof))

    # Another distinct seller envelope with the *same provider event ID*
    # cannot count that protected money twice.
    head = Log.head()
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, proof, @campaign, 1))
    assert Log.head() == head

    # Same provider/campaign/event_ref re-signed with conflicting facts
    # must be refused globally, not merely by the local escrow reducer.
    replaced =
      provider_report(ctx, @campaign, %{
        payload: %{proof.payload | amount_minor: 40_000}
      })

    head = Log.head()

    assert {:error, :provider_event_conflict} =
             GroupBuys.submit(evidence(ctx, replaced, @campaign, 1))

    assert Log.head() == head
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

  defp funded_contract(ctx, proof \\ nil) do
    admitted = contract(ctx)
    {:bytes, consent_bytes} = admitted.payload["consent"]
    {:ok, term} = Canonical.decode(consent_bytes)
    {:ok, consent} = CoopSubstrate.Protocol.Envelope.from_full_record_term(term)

    {:ok, proposal} =
      GroupBuys.funded_acceptance(
        consent,
        encode_report(proof || provider_report(ctx)),
        Map.get(ctx, :escrow_version, 0),
        ctx.seller.signer
      )

    {:ok, signed} =
      CoopSubstrate.Protocol.Envelope.sign(
        proposal,
        ctx.seller.signer.key_id,
        ctx.seller.seed
      )

    signed
  end

  test "seller self-pin is historical only; governance provenance and current authority required",
       ctx do
    legacy =
      signed_event(ctx.seller, "GroupBuyEscrowProviderPinnedV1", %{
        "seller_id" => @seller,
        "campaign_id" => @campaign,
        "provider_id" => @provider,
        "key_id" => "provider-signing-1",
        "pubkey" => {:bytes, ctx.provider_public},
        "active" => true,
        "expires_at" => ctx.now + 2400,
        "expected_version" => 0
      })

    rejected(legacy, :authenticated_provider_pin_required)

    rejected(
      pin(%{ctx | authority_id: "unrecorded-provider-authorization"}),
      :untrusted_or_stale_provider_authority
    )

    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    bind(ctx)
    renewed = provider_authority(ctx, %{"expected_version" => 1})
    assert {:ok, _} = GroupBuys.submit(renewed)
    rejected(evidence(ctx, provider_report(ctx)), :authenticated_provider_pin_required)
    rejected(pin(ctx, @campaign, 1), :untrusted_or_stale_provider_authority)
    assert {:ok, _} = GroupBuys.submit(pin(%{ctx | authority_id: renewed.event_id}, @campaign, 1))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))
    restart_log()
    authority = Log.gate().group_buys.escrow_authorities[{@chapter, @provider}]
    assert authority.provenance_ref == "fixture-only/independent-provider-review"
    assert authority.event_id == renewed.event_id
  end

  test "seller cannot fabricate governance provenance, and V1 histories still fold", ctx do
    attacker = new_member("governance")
    event = provider_authority(ctx, %{"expected_version" => 1})
    forged = signed_event(attacker, event.type, event.payload)
    rejected(forged, :group_buy_governance_required)
    bind(ctx)

    legacy =
      signed_event(ctx.seller, "GroupBuyEscrowProviderPinnedV1", %{
        "seller_id" => @seller,
        "campaign_id" => @campaign,
        "provider_id" => @provider,
        "key_id" => "provider-signing-1",
        "pubkey" => {:bytes, ctx.provider_public},
        "active" => true,
        "expires_at" => ctx.now + 2400,
        "expected_version" => 0
      })

    gate = Log.gate()
    historical = %{gate | group_buys: GroupBuys.fold!(legacy, gate)}
    report = evidence(ctx, provider_report(ctx))
    assert :ok = GroupBuys.check(report, historical)

    assert {:error, :authenticated_provider_pin_required} =
             GroupBuys.live_check(report, historical)

    # Already signed V1 funding and stock remain valid historical facts.
    historical = %{historical | group_buys: GroupBuys.fold!(report, historical)}
    receive = stock_event(ctx, stock_command("receive", "legacy-stock", 0))
    historical = %{historical | group_buys: GroupBuys.fold!(receive, historical)}
    reserve = stock_event(ctx, stock_command("reserve", "legacy-hold", 1))
    assert :ok = GroupBuys.check(reserve, historical)

    assert {:error, :stock_hold_requires_bound_funded_campaign} =
             GroupBuys.live_check(reserve, historical)

    historical = %{historical | group_buys: GroupBuys.fold!(reserve, historical)}

    assert {:error, :escrow_or_stock_not_ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               historical,
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    # Repinning alone is insufficient: the current provider must explicitly
    # sign the exact legacy allocation and its prior evidence hash.
    historical = %{historical | group_buys: GroupBuys.fold!(pin(ctx, @campaign, 1), historical)}

    assert {:error, :escrow_or_stock_not_ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               historical,
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    position =
      historical.group_buys.escrow_states[{@chapter, @seller, @campaign}].positions[@buyer]

    proof = reconfirmation(ctx, position, %{key_id: "provider-signing-1"})
    renewal = evidence(ctx, proof, @campaign, 1)
    assert :ok = GroupBuys.live_check(renewal, historical)
    historical = %{historical | group_buys: GroupBuys.fold!(renewal, historical)}

    assert {:ok, _} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               historical,
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )
  end

  test "inactive authority and stale provider pin revisions refuse new funding", ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    rejected(pin(ctx), :untrusted_or_stale_provider_authority)
    bind(ctx)

    assert {:ok, _} =
             GroupBuys.submit(
               provider_authority(ctx, %{
                 "active" => false,
                 "expected_version" => 1
               })
             )

    rejected(evidence(ctx, provider_report(ctx)), :authenticated_provider_pin_required)
  end

  test "partial or expired funding does not admit even one half of a funded contract", ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    proof = provider_report(ctx)
    partial = provider_report(ctx, @campaign, %{payload: %{proof.payload | amount_minor: 44_999}})
    rejected(funded_contract(ctx, partial), :invalid_or_duplicate_external_hold)

    expired =
      provider_report(ctx, @campaign, %{issued_at: ctx.now - 700, expires_at: ctx.now - 1})

    rejected(funded_contract(ctx, expired), :provider_proof_out_of_scope_or_stale)
    key = {@chapter, @seller, @campaign}
    assert Log.gate().group_buys.rounds[key].activated == nil
    assert Log.gate().group_buys.rounds[key].pledges == %{}
    assert Log.gate().group_buys.escrow_states[key].positions == %{}
    assert Log.gate().group_buys.escrow_provider_events == %{}
    restart_log()
    assert Log.gate().group_buys.rounds[key].activated == nil
  end

  test "one funded contract atomically crosses threshold, retries and replays", ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    event = funded_contract(ctx)
    before = Log.head().global_seq
    assert {:ok, receipt} = GroupBuys.submit(event)
    assert Log.head().global_seq == before + 1
    assert receipt.payment == :not_collected
    key = {@chapter, @seller, @campaign}
    state = Log.gate().group_buys
    assert state.rounds[key].activated != nil
    assert state.escrow_states[key].positions[@buyer].status == :held
    assert :ok = CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(state, key, ctx.now)
    restart_log()
    assert Log.gate().group_buys == state
    assert {:ok, ^receipt} = GroupBuys.submit(event)
    assert Log.head().global_seq == before + 1
    assert {:ok, replayed} = Log.replay(Membership)
    assert replayed.group_buys == state
  end

  test "funded coverage refuses expired, deactivated or historically unauthenticated funding sources",
       ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(funded_contract(ctx))
    key = {@chapter, @seller, @campaign}
    state = Log.gate().group_buys
    claim_key = {@provider, "escrow-allocation-1"}

    historical =
      update_in(state.escrow_custody_claims[claim_key], &Map.delete(&1, :authority_event_id))

    assert {:error, :funded_contract_requires_complete_held_evidence} =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(historical, key, ctx.now)

    expired = put_in(state.escrow_grants[{key, @provider}].grant_expires_at, ctx.now)

    assert {:error, :funded_contract_requires_complete_held_evidence} =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(expired, key, ctx.now)

    assert {:ok, _} =
             GroupBuys.submit(
               provider_authority(ctx, %{
                 "active" => false,
                 "expected_version" => 1
               })
             )

    assert {:error, :funded_contract_requires_complete_held_evidence} =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(
               Log.gate().group_buys,
               key,
               ctx.now
             )

    restart_log()

    assert {:error, :funded_contract_requires_complete_held_evidence} =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(
               Log.gate().group_buys,
               key,
               ctx.now
             )
  end

  test "callback lost-ack retries return original receipt after restart and authority rotation",
       ctx do
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    proof = provider_report(ctx)
    assert {:ok, original} = GroupBuys.submit(evidence(ctx, proof))

    assert {:ok, _} =
             GroupBuys.submit(
               provider_authority(ctx, %{
                 "active" => false,
                 "expected_version" => 1
               })
             )

    restart_log()
    before = Log.head()
    assert {:ok, ^original} = GroupBuys.submit(evidence(ctx, proof, @campaign, 99))
    assert Log.head() == before
    assert map_size(Log.gate().group_buys.escrow_provider_events) == 1
  end

  defp another_buyer(ctx) do
    buyer_id = @buyer <> "-second"
    buyer = new_member("group_buyer")
    registered = %{buyer | signer: %{buyer.signer | role: "member"}}

    assert {:ok, _} =
             Log.append(
               signed_event(registered, "MemberRegistered", %{
                 "member_id" => buyer_id,
                 "pubkey" => {:bytes, buyer.signer.pubkey},
                 "key_id" => buyer.signer.key_id
               })
             )

    assert {:ok, _} =
             GroupBuys.submit(
               signed_event(ctx.seller, "GroupBuyMemberAuthorizedV1", %{
                 "seller_id" => @seller,
                 "buyer_id" => buyer_id,
                 "key_id" => buyer.signer.key_id,
                 "pubkey" => {:bytes, buyer.signer.pubkey},
                 "expires_at" => ctx.now + 1800,
                 "expected_version" => 0,
                 "active" => true
               })
             )

    Map.merge(ctx, %{buyer: buyer, buyer_id: buyer_id, custody_ref: "escrow-allocation-2"})
  end

  test "funded threshold refuses unfunded earlier pledges without changing their conditional state",
       ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    bind(Map.put(ctx, :quantity, 3))
    second = another_buyer(ctx) |> Map.put(:round_version, 1)
    rejected(funded_contract(second), :funded_contract_requires_complete_held_evidence)
    key = {@chapter, @seller, @campaign}
    state = Log.gate().group_buys
    assert state.rounds[key].activated == nil
    assert map_size(state.rounds[key].pledges) == 1
    assert state.escrow_states[key].positions == %{}
    # Separately admitted evidence can protect the earlier conditional pledge.
    proof = provider_report(ctx)

    first_funding =
      provider_report(ctx, @campaign, %{payload: %{proof.payload | amount_minor: 27_000}})

    assert {:ok, _} = GroupBuys.submit(evidence(ctx, first_funding))
    assert {:ok, _} = GroupBuys.submit(funded_contract(Map.put(second, :escrow_version, 1)))

    assert :ok =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(
               Log.gate().group_buys,
               key,
               ctx.now
             )

    restart_log()
    assert Log.gate().group_buys.rounds[key].activated != nil
  end

  test "concurrent threshold attempts serialize contract, funds and nullifiers together", ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    second = another_buyer(ctx)
    events = [funded_contract(ctx), funded_contract(second)]

    results =
      events
      |> Enum.map(fn event -> Task.async(fn -> GroupBuys.submit(event) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    key = {@chapter, @seller, @campaign}
    assert Log.gate().group_buys.rounds[key].version == 1
    assert Log.gate().group_buys.escrow_states[key].version == 1
    assert map_size(Log.gate().group_buys.escrow_custody_claims) == 1
    restart_log()

    assert :ok =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(
               Log.gate().group_buys,
               key,
               ctx.now
             )
  end

  test "a journal transaction failure leaves neither contract nor funding; restart can retry",
       ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    before = Log.head()
    state = Log.gate().group_buys
    {:ok, conn} = raw_conn()

    Postgrex.query!(
      conn,
      """
      CREATE FUNCTION fail_escrow_insert() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test-only interrupted escrow append'; END $$
      """,
      []
    )

    Postgrex.query!(
      conn,
      "CREATE TRIGGER fail_escrow_insert BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION fail_escrow_insert()",
      []
    )

    try do
      # Sign immediately before dispatch, after installing the failure trigger.
      assert {:error, {:store_append_failed, _}} = GroupBuys.submit(funded_contract(ctx))
      assert Log.head() == before
      assert Log.gate().group_buys == state
    after
      Postgrex.query!(conn, "DROP TRIGGER fail_escrow_insert ON events", [])
      Postgrex.query!(conn, "DROP FUNCTION fail_escrow_insert()", [])
      GenServer.stop(conn)
    end

    restart_log()
    assert Log.gate().group_buys == state
    # Resign in the new live second after recovery; original consent still valid.
    assert {:ok, _} = GroupBuys.submit(funded_contract(ctx))
  end

  test "restart recovers a committed but unacknowledged funded event and repairs missing links",
       ctx do
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    event = funded_contract(ctx)
    # Model the exact crash boundary after EventStore commit, before link,
    # notification, in-memory fold or acknowledgement. Test-only direct write.
    gate = Log.gate()
    assert :ok = GroupBuys.live_check(event, gate)
    head = Log.head()
    {:ok, stream} = CoopSubstrate.Protocol.Envelope.stream_id(event)
    {:ok, prior} = Log.read_stream(stream)
    last = List.last(prior)
    {:ok, previous_hash} = CoopSubstrate.Protocol.Envelope.event_hash(last)

    assigned =
      CoopSubstrate.Protocol.Envelope.with_log_assignment(event, %{
        stream_id: stream,
        stream_seq: last.stream_seq + 1,
        global_seq: head.global_seq + 1,
        prev_global_hash: head.global_hash,
        prev_stream_hash: previous_hash
      })

    {:ok, uuid} = CoopSubstrate.ULID.to_uuid(event.event_id)

    data = %EventStore.EventData{
      event_id: uuid,
      event_type: event.type,
      data: Canonical.encode!(CoopSubstrate.Protocol.Envelope.full_record_term(assigned)),
      metadata: nil
    }

    assert :ok = CoopSubstrate.EventStore.append_to_stream("ledger", head.global_seq, [data])
    # The running appender has not seen the durable event.
    assert Log.head() == head
    assert Log.gate() == gate
    restart_log()
    assert Log.head().global_seq == head.global_seq + 1
    key = {@chapter, @seller, @campaign}

    assert :ok =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(
               Log.gate().group_buys,
               key,
               ctx.now
             )

    assert {:ok, repaired} = Log.read_stream(stream)
    assert List.last(repaired) == assigned
    before_retry = Log.head()
    assert {:ok, _} = GroupBuys.submit(event)
    assert Log.head() == before_retry
    assert :ok = Log.verify_chains()
  end

  test "provider event identity is global even when second campaign has independent custody",
       ctx do
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    first = provider_report(ctx)
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, first))
    second = @campaign <> "-event-reuse"
    offer = posted_offer(ctx.seller, second, ctx.now)
    assert {:ok, _} = GroupBuys.submit(offer)
    {:ok, hash} = GroupBuys.terms_hash(offer)
    bind(ctx, second, hash)
    assert {:ok, _} = GroupBuys.submit(pin(ctx, second))

    proof =
      provider_report(ctx, second, %{payload: %{first.payload | custody_ref: "different-custody"}})

    before = Log.head()
    assert {:error, :provider_event_conflict} = GroupBuys.submit(evidence(ctx, proof, second))
    assert Log.head() == before
    assert Log.gate().group_buys.escrow_states[{@chapter, @seller, second}].positions == %{}
  end

  test "exact atomic batch retries are idempotent while mixed old/new batches refuse", ctx do
    bind(ctx)
    provider_pin = pin(ctx)
    report = evidence(ctx, provider_report(ctx))
    assert {:ok, first} = Log.append([provider_pin, report])
    head = Log.head()
    restart_log()
    assert {:ok, ^first} = Log.append([provider_pin, report])

    assert {:error, :partial_group_buy_batch_replay} =
             Log.append([provider_pin, pin(ctx, @campaign, 1)])

    assert Log.head() == head
  end

  defp rotated_provider(ctx) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    rotated = %{ctx | provider_public: public, provider_private: private}

    authority =
      provider_authority(rotated, %{"expected_version" => 1, "key_id" => "provider-signing-2"})

    assert {:ok, _} = GroupBuys.submit(authority)
    %{rotated | authority_id: authority.event_id}
  end

  defp reconfirmation(ctx, position, changes \\ %{}) do
    provider_report(
      ctx,
      @campaign,
      Map.merge(
        %{
          key_id: "provider-signing-2",
          event_ref: "funding-reconfirmed",
          payload: %{
            op: :hold_reconfirmed,
            buyer: position.buyer,
            pledge_id: position.pledge_id,
            custody_ref: position.custody_ref,
            currency: position.currency,
            amount_minor: position.amount_minor,
            expires_at: position.expires_at + 600,
            prior_funding_evidence_ref: position.funding_evidence_ref
          }
        },
        changes
      )
    )
  end

  test "current provider re-attestation restores readiness after rotation without new funds or stock",
       ctx do
    key = {@chapter, @seller, @campaign}
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))

    assert {:ok, _} =
             GroupBuys.submit(stock_event(ctx, stock_command("receive", "reconcile-stock", 0)))

    assert {:ok, _} =
             GroupBuys.submit(stock_event(ctx, stock_command("reserve", "reconcile-hold", 1)))

    original = Log.gate().group_buys
    position = original.escrow_states[key].positions[@buyer]
    rotated = rotated_provider(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(rotated, @campaign, 1))

    assert {:error, :escrow_or_stock_not_ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               Log.gate(),
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    proof = reconfirmation(rotated, position)
    head = Log.head()
    assert {:ok, receipt} = GroupBuys.submit(evidence(rotated, proof, @campaign, 1))
    assert receipt.payment == :not_collected
    assert Log.head().global_seq == head.global_seq + 1
    current = Log.gate().group_buys
    updated = current.escrow_states[key].positions[@buyer]
    assert updated.amount_minor == position.amount_minor
    assert updated.custody_ref == position.custody_ref
    assert updated.expires_at == position.expires_at + 600
    assert current.stock_aggregates == original.stock_aggregates
    assert current.stock_claims == original.stock_claims
    assert map_size(current.escrow_custody_claims) == 1
    assert map_size(current.escrow_provider_events) == 2

    assert current.escrow_custody_claims[{@provider, position.custody_ref}].authority_event_id ==
             rotated.authority_id

    assert {:ok, ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               Log.gate(),
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    assert ready.verified_provider_funding_minor == 45_000
    assert ready.settlement == :not_authorized
    restart_log()
    assert Log.gate().group_buys == current
    assert {:ok, ^receipt} = GroupBuys.submit(evidence(rotated, proof, @campaign, 999))
    assert Log.head().global_seq == head.global_seq + 1
    assert {:ok, replayed} = Log.replay(Membership)
    assert replayed.group_buys == current
    assert :ok = Log.verify_chains()
  end

  test "old keys, altered money and missing current grant cannot reconcile funding", ctx do
    key = {@chapter, @seller, @campaign}
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))
    position = Log.gate().group_buys.escrow_states[key].positions[@buyer]
    rotated = rotated_provider(ctx)
    proof = reconfirmation(rotated, position)
    rejected(evidence(rotated, proof, @campaign, 1), :authenticated_provider_pin_required)
    assert {:ok, _} = GroupBuys.submit(pin(rotated, @campaign, 1))
    old_key = reconfirmation(ctx, position, %{key_id: "provider-signing-1"})
    rejected(evidence(ctx, old_key, @campaign, 1), :provider_proof_out_of_scope_or_stale)
    forged = reconfirmation(ctx, position)
    rejected(evidence(ctx, forged, @campaign, 1), :invalid_provider_signature)

    altered =
      reconfirmation(rotated, position, %{payload: %{proof.payload | amount_minor: 45_001}})

    rejected(
      evidence(rotated, altered, @campaign, 1),
      :reconfirmation_requires_same_held_allocation_and_prior_evidence
    )

    assert Log.gate().group_buys.escrow_states[key].positions[@buyer] == position
    assert map_size(Log.gate().group_buys.escrow_provider_events) == 1
  end

  test "re-attestation cannot take another campaign's existing custody allocation", ctx do
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))

    position =
      Log.gate().group_buys.escrow_states[{@chapter, @seller, @campaign}].positions[@buyer]

    second = @campaign <> "-reconcile-theft"
    offer = posted_offer(ctx.seller, second, ctx.now)
    assert {:ok, _} = GroupBuys.submit(offer)
    {:ok, hash} = GroupBuys.terms_hash(offer)
    bind(ctx, second, hash)
    rotated = rotated_provider(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(rotated, second))
    base = reconfirmation(rotated, position)

    proof =
      provider_report(rotated, second, %{
        key_id: "provider-signing-2",
        event_ref: "foreign-recheck",
        payload: base.payload
      })

    rejected(evidence(rotated, proof, second), :unowned_or_cross_campaign_custody)
  end

  test "concurrent re-attestations serialize and stale prior evidence cannot branch after restart",
       ctx do
    key = {@chapter, @seller, @campaign}
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))
    position = Log.gate().group_buys.escrow_states[key].positions[@buyer]
    rotated = rotated_provider(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(rotated, @campaign, 1))

    proofs =
      for ref <- ["recheck-a", "recheck-b"],
          do: reconfirmation(rotated, position, %{event_ref: ref})

    results =
      proofs
      |> Enum.map(fn proof ->
        Task.async(fn -> GroupBuys.submit(evidence(rotated, proof, @campaign, 1)) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    restart_log()
    assert Log.gate().group_buys.escrow_states[key].version == 2
    assert map_size(Log.gate().group_buys.escrow_provider_events) == 2
    stale = reconfirmation(rotated, position, %{event_ref: "stale-prior-recheck"})

    rejected(
      evidence(rotated, stale, @campaign, 2),
      :reconfirmation_requires_same_held_allocation_and_prior_evidence
    )

    assert :ok =
             CoopSubstrate.GroupBuys.EscrowAdmission.complete_coverage(
               Log.gate().group_buys,
               key,
               ctx.now
             )
  end

  defp stock_event(ctx, command, campaign \\ @campaign) do
    signed_event(ctx.seller, "GroupBuyStockCommandAdmittedV1", %{
      "seller_id" => @seller,
      "campaign_id" => campaign,
      "command" => command,
      "source_ref" => "seller-attested-warehouse-source-needs-physical-proof"
    })
  end

  defp stock_command(op, id, revision, count \\ 5, overrides \\ %{}) do
    body =
      %{
        "schema" => "bizkit.inventory.command.v1",
        "merchant" => @seller,
        "item" => "parts",
        "unit" => "piece",
        "op" => op,
        "id" => id,
        "expected_version" => revision,
        "location" => "warehouse",
        "quantity" => count
      }

    body =
      if op == "reserve" do
        Map.merge(body, %{
          "reservation_id" => "group-reservation-" <> id,
          "expires_at_ms" => (System.system_time(:second) + 1200) * 1_000
        })
      else
        body
      end

    Map.merge(body, overrides)
  end

  test "ready only with seller-ledger admitted stock AND signed escrow coverage; recover both",
       ctx do
    key = {@chapter, @seller, @campaign}
    bind(ctx)

    assert {:error, :escrow_or_stock_not_ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               Log.gate(),
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))

    assert {:error, :escrow_or_stock_not_ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               Log.gate(),
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    assert {:ok, _} =
             GroupBuys.submit(stock_event(ctx, stock_command("receive", "stock-received-1", 0)))

    assert {:error, :escrow_or_stock_not_ready} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               Log.gate(),
               @chapter,
               @seller,
               @campaign,
               ctx.now
             )

    assert {:ok, _} = GroupBuys.submit(stock_event(ctx, stock_command("reserve", "hold-1", 1)))

    {:ok, ready} =
      CoopSubstrate.GroupBuys.Stock.readiness(
        Log.gate(),
        @chapter,
        @seller,
        @campaign,
        System.system_time(:second)
      )

    assert ready.contracted_quantity == 5
    assert ready.verified_provider_funding_minor == 45_000
    assert ready.current_due_minor == 45_000
    assert ready.assurance == :seller_home_committed_stock_and_provider_evidence
    assert ready.physical_stock == :not_independently_verified
    assert ready.settlement == :not_authorized

    stock_key = {@chapter, @seller, "parts", "piece"}
    before = Log.gate().group_buys.stock_aggregates[stock_key]
    assert before.version == 2
    assert Log.gate().group_buys.stock_claims[key].quantity == 5
    assert {:ok, 0} = InventoryCore.available(before, @seller, "warehouse")

    assert :ok = Log.verify_chains()
    restart_log()
    assert Log.gate().group_buys.stock_aggregates[stock_key] == before

    assert {:ok, _} =
             CoopSubstrate.GroupBuys.Stock.readiness(
               Log.gate(),
               @chapter,
               @seller,
               @campaign,
               System.system_time(:second)
             )

    assert {:ok, replayed} = Log.replay(Membership)
    assert replayed.group_buys == Log.gate().group_buys
  end

  test "unfunded binding cannot reserve stock, and rejected holds never change canonical head",
       ctx do
    bind(ctx)

    assert {:ok, _} =
             GroupBuys.submit(stock_event(ctx, stock_command("receive", "stock-received", 0)))

    rejected(
      stock_event(ctx, stock_command("reserve", "unfunded", 1)),
      :stock_hold_requires_bound_funded_campaign
    )

    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))

    rejected(
      stock_event(
        ctx,
        stock_command("reserve", "wrong-scope", 1, 5, %{
          "item" => "someone-elses-stock"
        })
      ),
      :wrong_inventory_scope
    )

    rejected(
      stock_event(ctx, stock_command("reserve", "too-many", 1, 6)),
      :stock_hold_requires_bound_funded_campaign
    )

    assert {:ok, _} = GroupBuys.submit(stock_event(ctx, stock_command("reserve", "valid", 1)))

    rejected(
      stock_event(ctx, stock_command("reserve", "duplicate-campaign", 2)),
      :stock_hold_requires_bound_funded_campaign
    )

    rejected(
      stock_event(ctx, stock_command("receive", "stale-version", 1)),
      :stale_stock_version
    )

    release = %{
      "schema" => "bizkit.inventory.command.v1",
      "merchant" => @seller,
      "item" => "parts",
      "unit" => "piece",
      "op" => "release",
      "id" => "release-not-authorized",
      "expected_version" => 2,
      "reservation_id" => "group-reservation-valid"
    }

    rejected(stock_event(ctx, release), :stock_command_not_allowed)
  end

  test "distinct campaigns share seller's one stock pool and cannot both hold same units",
       ctx do
    bind(ctx)
    assert {:ok, _} = GroupBuys.submit(pin(ctx))
    assert {:ok, _} = GroupBuys.submit(evidence(ctx, provider_report(ctx)))
    assert {:ok, _} = GroupBuys.submit(stock_event(ctx, stock_command("receive", "receive", 0)))
    assert {:ok, _} = GroupBuys.submit(stock_event(ctx, stock_command("reserve", "hold-a", 1)))

    second = @campaign <> "-stock-second"
    signed_offer = posted_offer(ctx.seller, second, ctx.now)
    assert {:ok, _} = GroupBuys.submit(signed_offer)
    {:ok, hash} = GroupBuys.terms_hash(signed_offer)
    bind(ctx, second, hash)
    assert {:ok, _} = GroupBuys.submit(pin(ctx, second))

    second_provider =
      provider_report(ctx, second, %{
        event_ref: "second-custodian-event",
        payload: %{
          op: :hold_confirmed,
          buyer: @buyer,
          pledge_id: @buyer <> "/pledge/escrow",
          custody_ref: "independent-funding-allocation-b",
          currency: "USD",
          amount_minor: 45_000,
          expires_at: ctx.now + 3000
        }
      })

    assert {:ok, _} = GroupBuys.submit(evidence(ctx, second_provider, second))

    rejected(
      stock_event(ctx, stock_command("reserve", "hold-b", 2), second),
      :insufficient_available
    )

    stock_key = {@chapter, @seller, "parts", "piece"}

    assert {:ok, 0} =
             InventoryCore.available(
               Log.gate().group_buys.stock_aggregates[stock_key],
               @seller,
               "warehouse"
             )
  end
end
