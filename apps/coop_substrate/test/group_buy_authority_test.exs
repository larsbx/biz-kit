defmodule CoopSubstrate.GroupBuyAuthorityTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{Canonical, GroupBuys, Log}
  alias CoopSubstrate.GroupBuys.Cipher
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope
  alias GroupBuyCore.BindingRound, as: Round

  @seller "https://seller.example/actors/seller"
  @buyer "https://buyer.example/actors/buyer"
  @other "https://other.example/actors/buyer"
  @campaign "https://seller.example/group-buys/parts"
  @ch "chapter-genesis"
  @key {@ch, @seller, @campaign}

  setup do
    now = System.system_time(:second)
    gov = new_member("governance")
    seller = new_member("group_seller")
    buyer = new_member("group_buyer")
    other = new_member("group_buyer")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    grant =
      signed_event(gov, "GroupBuySellerAuthorizedV1", %{
        "seller_id" => @seller,
        "key_id" => seller.signer.key_id,
        "pubkey" => {:bytes, seller.signer.pubkey},
        "expires_at" => now + 3600,
        "expected_version" => 0
      })

    {:ok, _} = GroupBuys.submit(grant)
    ctx = %{gov: gov, seller: seller, buyer: buyer, other: other, now: now, grant: grant}

    for {id, actor} <- [{@buyer, buyer}, {@other, other}] do
      {:ok, _} = GroupBuys.submit(member(ctx, id, actor))
    end

    posted = offer(ctx)
    {:ok, _} = GroupBuys.submit(posted)
    {:ok, hash} = GroupBuys.terms_hash(posted)
    {:ok, Map.merge(ctx, %{posted: posted, hash: hash})}
  end

  defp member(ctx, id, actor, version \\ 0, active \\ true) do
    signed_event(ctx.seller, "GroupBuyMemberAuthorizedV1", %{
      "seller_id" => @seller,
      "buyer_id" => id,
      "key_id" => actor.signer.key_id,
      "pubkey" => {:bytes, actor.signer.pubkey},
      "expires_at" => ctx.now + 1800,
      "expected_version" => version,
      "active" => active
    })
  end

  defp offer(ctx, changes \\ %{}) do
    raw = %{
      "id" => @campaign,
      "seller" => @seller,
      "sku" => "parts",
      "unit" => "piece",
      "currency" => "USD",
      "revision" => 3,
      "expires_at" => ctx.now + 600,
      "capacity" => 30,
      "solo_unit_minor" => 10_000,
      "tiers" => [
        %{"min_quantity" => 5, "unit_minor" => 9_000},
        %{"min_quantity" => 10, "unit_minor" => 8_000}
      ]
    }

    signed_event(ctx.seller, "GroupBuyOfferPostedV1", %{
      "seller_id" => @seller,
      "campaign_id" => @campaign,
      "offer" => Map.merge(raw, changes),
      "policy" => GroupBuys.policy()
    })
  end

  defp pledge(ctx, actor, buyer, qty, version, changes \\ %{}) do
    command = %{
      "op" => "pledge",
      "expected_version" => version,
      "pledge" => %{
        "id" => buyer <> "/pledge/#{version}",
        "buyer" => buyer,
        "offer_id" => @campaign,
        "offer_revision" => 3,
        "quantity" => qty,
        "max_group_unit_minor" => 9_000,
        "expires_at" => ctx.now + 100
      }
    }

    consent(ctx, actor, buyer, Map.merge(command, changes))
  end

  defp consent(ctx, actor, buyer, command) do
    signed_event(actor, "GroupBuyConsentV1", %{
      "seller_id" => @seller,
      "campaign_id" => @campaign,
      "buyer_id" => buyer,
      "terms_hash" => {:bytes, ctx.hash},
      "policy" => GroupBuys.policy(),
      "command" => command,
      "valid_until" => ctx.now + 100
    })
  end

  defp admission(ctx, consent) do
    {:ok, env} = GroupBuys.acceptance(consent, ctx.seller.signer)
    {:ok, env} = Envelope.sign(env, ctx.seller.signer.key_id, ctx.seller.seed)
    env
  end

  defp read(ctx, actor, buyer, public) do
    signed_event(actor, "GroupBuyPrivateReadV1", %{
      "seller_id" => @seller,
      "campaign_id" => @campaign,
      "buyer_id" => buyer,
      "terms_hash" => {:bytes, ctx.hash},
      "encryption_key" => {:bytes, public},
      "valid_until" => ctx.now + 60
    })
  end

  defp rejected(env, reason) do
    before = Log.head()
    assert {:error, {:reject, 0, ^reason}} = Log.append(env)
    assert Log.head() == before
    assert :ok = Log.verify_chains()
  end

  test "only admitted signed seller-home contracts contribute; activation is atomic and durable",
       ctx do
    first = pledge(ctx, ctx.buyer, @buyer, 2, 0)
    rejected(first, :consent_is_not_ledger_admission)
    assert Log.gate().group_buys.rounds[@key].version == 0
    assert {:ok, receipt} = GroupBuys.submit(admission(ctx, first))
    assert receipt.payment == :not_collected
    assert receipt.inventory == :not_reserved
    assert receipt.fulfillment == :not_authorized
    state = Log.gate().group_buys.rounds[@key]
    assert state.activated == nil
    assert {:ok, _} = GroupBuys.submit(admission(ctx, pledge(ctx, ctx.other, @other, 3, 1)))
    state = Log.gate().group_buys.rounds[@key]
    assert {:ok, view} = Round.snapshot(state, System.system_time(:second))
    assert view.contracted_quantity == 5
    assert view.total_due_minor == 45_000
    assert view.group_unit_minor == 9_000
    assert view.payment_status == :not_collected
    assert view.stock_status == :not_reserved
    restart_log()
    assert Log.gate().group_buys.rounds[@key] == state
    assert {:ok, replayed} = Log.replay(Membership)
    assert replayed.group_buys == Log.gate().group_buys
    assert :ok = Log.verify_chains()
  end

  test "forged membership, substituted buyer keys and self-appointed seller keys fail closed",
       ctx do
    attacker = new_member("group_buyer")

    rejected(
      admission(ctx, pledge(ctx, attacker, @buyer, 5, 0)),
      :invalid_or_expired_group_buy_credential
    )

    rejected(
      admission(ctx, pledge(ctx, attacker, "https://unknown.example/buyer", 5, 0)),
      :ineligible_group_buy_member
    )

    fake = new_member("governance")
    bad_grant = signed_event(fake, "GroupBuySellerAuthorizedV1", ctx.grant.payload)
    assert {:error, _} = Log.append(bad_grant)
    bad_seller = new_member("group_seller")
    {:ok, env} = GroupBuys.acceptance(pledge(ctx, ctx.buyer, @buyer, 5, 0), bad_seller.signer)
    {:ok, env} = Envelope.sign(env, bad_seller.signer.key_id, bad_seller.seed)
    rejected(env, :invalid_or_expired_group_buy_credential)
  end

  test "tampered consent signatures and altered signed terms never reach the ledger", ctx do
    original = pledge(ctx, ctx.buyer, @buyer, 5, 0)

    {:ok, raw} =
      Canonical.encode(
        Envelope.full_record_term(%{
          original
          | payload: Map.put(original.payload, "policy", "optional-purchase")
        })
      )

    env =
      signed_event(ctx.seller, "GroupBuyContractAdmittedV1", %{
        "seller_id" => @seller,
        "campaign_id" => @campaign,
        "consent" => {:bytes, raw}
      })

    rejected(env, :invalid_signed_consent)

    stale =
      consent(
        %{ctx | hash: :crypto.hash(:sha256, "old price ladder")},
        ctx.buyer,
        @buyer,
        original.payload["command"]
      )

    rejected(admission(ctx, stale), :stale_closed_or_expired_offer)
    rejected(offer(ctx, %{"solo_unit_minor" => 20_000}), :immutable_or_mismatched_offer)

    wrong_policy =
      signed_event(
        ctx.buyer,
        "GroupBuyConsentV1",
        Map.put(original.payload, "policy", "nonbinding-interest")
      )

    rejected(admission(ctx, wrong_policy), :consent_scope_or_policy_mismatch)
  end

  test "private delivery requires current membership and recipient-bound authenticated encryption",
       ctx do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    request = read(ctx, ctx.buyer, @buyer, public)
    assert {:error, :private_delivery_required} = GroupBuys.deliver(request, :activitypub_public)
    assert {:error, :private_delivery_required} = GroupBuys.deliver(request, :iroh_gossip)
    assert {:ok, packet} = GroupBuys.deliver(request, :private)
    refute inspect(packet) =~ "solo_unit_minor"
    assert {:ok, bytes} = Cipher.open(packet, private, request)
    {:ok, term} = Canonical.decode(bytes)
    {:ok, seller_offer} = Envelope.from_full_record_term(term)
    assert :ok = Envelope.verify(seller_offer)
    assert {:ok, ctx.hash} == GroupBuys.terms_hash(seller_offer)
    assert seller_offer.payload["offer"]["solo_unit_minor"] == 10_000
    {_, wrong_private} = :crypto.generate_key(:ecdh, :x25519)
    assert {:error, :invalid_private_packet} = Cipher.open(packet, wrong_private, request)
    changed = %{request | payload: Map.put(request.payload, "buyer_id", @other)}
    assert {:error, :invalid_private_packet} = Cipher.open(packet, private, changed)
    assert {:error, :private_read_replayed} = GroupBuys.deliver(request, :private)
    {:ok, _} = GroupBuys.submit(member(ctx, @buyer, ctx.buyer, 1, false))

    assert {:error, {:reject, 0, :ineligible_group_buy_member}} =
             GroupBuys.deliver(read(ctx, ctx.buyer, @buyer, public), :private)

    assert GroupBuyCore.MemberOffers.public_projection(ctx.posted) ==
             {:error, :members_only_no_public_projection}
  end

  test "replay and duplicate admission cannot increase quantity, even under concurrent submission",
       ctx do
    signed = pledge(ctx, ctx.buyer, @buyer, 5, 0)
    event = admission(ctx, signed)
    results = 1..6 |> Task.async_stream(fn _ -> GroupBuys.submit(event) end) |> Enum.to_list()
    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert Log.gate().group_buys.rounds[@key].version == 1
    rejected(admission(ctx, signed), :consent_replay)

    altered =
      signed_event(ctx.seller, event.type, event.payload,
        event_id: event.event_id,
        timestamp_ms: event.timestamp_ms + 1
      )

    assert {:error, :group_buy_event_id_conflict} = Log.append(altered)
    restart_log()
    assert Log.gate().group_buys.rounds[@key].version == 1
  end

  test "withdrawal and threshold race serialize, so both conflicting transitions cannot win",
       ctx do
    first = pledge(ctx, ctx.buyer, @buyer, 2, 0)
    {:ok, _} = GroupBuys.submit(admission(ctx, first))

    withdrawal =
      consent(ctx, ctx.buyer, @buyer, %{
        "op" => "withdraw",
        "expected_version" => 1,
        "pledge_id" => first.payload["command"]["pledge"]["id"]
      })

    events = [admission(ctx, withdrawal), admission(ctx, pledge(ctx, ctx.other, @other, 3, 1))]
    results = events |> Task.async_stream(&GroupBuys.submit/1) |> Enum.map(fn {:ok, x} -> x end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:reject, 0, :stale_binding_version}}, &1)) == 1
    state = Log.gate().group_buys.rounds[@key]
    assert state.version == 2

    if state.activated != nil do
      rejected(
        admission(
          ctx,
          consent(ctx, ctx.buyer, @buyer, %{
            withdrawal.payload["command"]
            | "expected_version" => 2
          })
        ),
        :binding_pledge_cannot_be_withdrawn
      )
    else
      assert state.pledges == %{}
    end
  end

  test "expired authority and offers and backdated admissions cannot bind", ctx do
    expired =
      signed_event(
        ctx.buyer,
        "GroupBuyConsentV1",
        Map.put(
          pledge(ctx, ctx.buyer, @buyer, 5, 0).payload,
          "valid_until",
          ctx.now
        )
      )

    rejected(admission(ctx, expired), :expired_group_buy_authority)
    # An expired posted offer cannot be installed even with a valid seller key.
    expired_offer = offer(ctx, %{"id" => @campaign <> "-expired", "expires_at" => ctx.now})

    expired_offer =
      signed_event(
        ctx.seller,
        expired_offer.type,
        Map.put(expired_offer.payload, "campaign_id", @campaign <> "-expired")
      )

    assert {:error, _} = GroupBuys.submit(expired_offer)
    event = admission(ctx, pledge(ctx, ctx.buyer, @buyer, 5, 0))

    backdated =
      signed_event(ctx.seller, event.type, event.payload, timestamp_ms: (ctx.now - 1) * 1000)

    rejected(backdated, :stale_admission_time)

    closed =
      signed_event(ctx.seller, "GroupBuyOfferClosedV1", %{
        "seller_id" => @seller,
        "campaign_id" => @campaign
      })

    {:ok, _} = GroupBuys.submit(closed)

    rejected(
      admission(ctx, pledge(ctx, ctx.buyer, @buyer, 5, 0)),
      :stale_closed_or_expired_offer
    )
  end

  test "membership withdrawal before threshold cannot contribute contractual volume", ctx do
    {:ok, _} = GroupBuys.submit(admission(ctx, pledge(ctx, ctx.buyer, @buyer, 2, 0)))
    {:ok, _} = GroupBuys.submit(member(ctx, @buyer, ctx.buyer, 1, false))
    rejected(admission(ctx, pledge(ctx, ctx.other, @other, 3, 1)), :pending_member_ineligible)
    assert Log.gate().group_buys.rounds[@key].activated == nil
    assert Log.gate().group_buys.rounds[@key].version == 1
  end

  test "expired new pledge cannot join an active group although consent admission deadline is current",
       ctx do
    {:ok, _} = GroupBuys.submit(admission(ctx, pledge(ctx, ctx.buyer, @buyer, 5, 0)))
    original = pledge(ctx, ctx.other, @other, 1, 1)
    command = put_in(original.payload["command"], ["pledge", "expires_at"], ctx.now)

    expired =
      signed_event(ctx.other, original.type, Map.put(original.payload, "command", command))

    rejected(admission(ctx, expired), :expired_pledge)
    state = Log.gate().group_buys.rounds[@key]
    assert {:ok, view} = Round.snapshot(state, ctx.now + 101)
    assert view.contracted_quantity == 5
    assert state.version == 1
  end

  test "a previously admitted offer cannot be used after its deadline", ctx do
    expires = System.system_time(:second) + 2
    campaign = @campaign <> "-short"
    posted = offer(ctx, %{"id" => campaign, "expires_at" => expires})

    posted =
      signed_event(ctx.seller, posted.type, Map.put(posted.payload, "campaign_id", campaign))

    {:ok, _} = GroupBuys.submit(posted)
    {:ok, hash} = GroupBuys.terms_hash(posted)
    original = pledge(ctx, ctx.buyer, @buyer, 5, 0)
    command = put_in(original.payload["command"], ["pledge", "offer_id"], campaign)

    payload =
      original.payload
      |> Map.put("campaign_id", campaign)
      |> Map.put("terms_hash", {:bytes, hash})
      |> Map.put("command", command)

    buyer_consent = signed_event(ctx.buyer, original.type, payload)
    Process.sleep(max(expires * 1000 - System.system_time(:millisecond), 0) + 10)
    rejected(admission(ctx, buyer_consent), :stale_closed_or_expired_offer)
    {public, _} = :crypto.generate_key(:ecdh, :x25519)
    request = read(ctx, ctx.buyer, @buyer, public)

    request =
      signed_event(
        ctx.buyer,
        request.type,
        request.payload
        |> Map.put("campaign_id", campaign)
        |> Map.put("terms_hash", {:bytes, hash})
      )

    assert {:error, {:reject, 0, :stale_closed_or_expired_offer}} =
             GroupBuys.deliver(request, :private)
  end

  @tag :tampers_ledger
  test "startup refuses corrupted durable group-buy history", ctx do
    {:ok, _} = GroupBuys.submit(admission(ctx, pledge(ctx, ctx.buyer, @buyer, 5, 0)))

    with_update_bypass(fn conn ->
      %{rows: [[id, bytes]]} =
        Postgrex.query!(conn, "SELECT event_id, data FROM events WHERE event_type = $1", [
          "GroupBuyContractAdmittedV1"
        ])

      {:ok, term} = Canonical.decode(bytes)
      corrupt = Map.put(term, "global_seq", term["global_seq"] + 1)

      Postgrex.query!(conn, "UPDATE events SET data = $1 WHERE event_id = $2", [
        Canonical.encode!(corrupt),
        id
      ])
    end)

    assert {:error, _} = Log.verify_chains()
    old = Process.flag(:trap_exit, true)

    try do
      assert {:error, _} = Log.start_link(name: :corrupt_group_buy_recovery_probe)
      assert_receive {:EXIT, _, _}
    after
      Process.flag(:trap_exit, old)
    end
  end

  test "malformed and foreign consents fail without killing the appender", ctx do
    invalid = consent(ctx, ctx.buyer, @buyer, 5)
    rejected(admission(ctx, invalid), :invalid_signed_group_buy_command)
    original = pledge(ctx, ctx.buyer, @buyer, 5, 0)
    foreign = signed_event(ctx.buyer, original.type, original.payload, chapter_id: "other-home")
    {:ok, bytes} = Canonical.encode(Envelope.full_record_term(foreign))

    env =
      signed_event(ctx.seller, "GroupBuyContractAdmittedV1", %{
        "seller_id" => @seller,
        "campaign_id" => @campaign,
        "consent" => {:bytes, bytes}
      })

    rejected(env, :consent_scope_or_policy_mismatch)
    assert {:ok, _} = GroupBuys.submit(admission(ctx, original))
  end

  test "recovery rejects inconsistent transitions, duplicates, credentials and invalid signatures",
       ctx do
    env = admission(ctx, pledge(ctx, ctx.buyer, @buyer, 5, 0))
    gate = Log.gate()
    folded = Membership.handle_event(env, gate)

    assert_raise RuntimeError, ~r/inconsistent group-buy history/, fn ->
      Membership.handle_event(env, folded)
    end

    next = admission(ctx, pledge(ctx, ctx.other, @other, 3, 99))

    assert_raise RuntimeError, ~r/inconsistent group-buy history/, fn ->
      Membership.handle_event(next, gate)
    end

    tampered = %{env | sigs: %{ctx.seller.signer.key_id => <<0::512>>}}

    assert_raise RuntimeError, ~r/inconsistent group-buy history/, fn ->
      Membership.handle_event(tampered, gate)
    end

    missing_grant = put_in(gate.group_buys.sellers, %{})

    assert_raise RuntimeError, ~r/inconsistent group-buy history/, fn ->
      Membership.handle_event(env, missing_grant)
    end
  end
end
