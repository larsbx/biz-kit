defmodule GroupBuyCore.ContractedTest do
  use ExUnit.Case, async: true

  alias GroupBuyCore, as: G
  alias GroupBuyCore.{Contracted, MemberOffers}

  @now 1_800_000_000

  defp offer(overrides \\ %{}) do
    Map.merge(
      %{
        id: "https://seller.example/group-buys/part-a",
        seller: "https://seller.example/actors/shop",
        sku: "part-a",
        unit: "piece",
        currency: "USD",
        revision: 7,
        expires_at: @now + 2_000,
        capacity: 200,
        solo_unit_minor: 10_000,
        tiers: [
          %{min_quantity: 5, unit_minor: 9_000},
          %{min_quantity: 10, unit_minor: 8_000}
        ]
      },
      overrides
    )
  end

  defp actor(name), do: "https://#{name}.example/actors/member"

  defp contract(state, name, quantity, overrides \\ %{}) do
    Map.merge(
      %{
        id: "contract-command-#{name}",
        expected_version: state.version,
        op: :contract,
        buyer: actor(name),
        offer_id: state.offer.id,
        offer_revision: state.offer.revision,
        contract_id: "binding-#{name}-1",
        quantity: quantity,
        max_group_unit_minor: 9_000,
        expires_at: @now + 1_000,
        evidence_ref: "host-must-verify-buyer-signature-#{name}"
      },
      overrides
    )
  end

  defp accepted(state, buyer, quantity, overrides \\ %{}) do
    command = contract(state, buyer, quantity, overrides)
    {:ok, next, :accepted} = Contracted.apply(state, actor(buyer), command, @now)
    next
  end

  test "members-only private offer includes seller prices and rates; no public projection" do
    context = %{
      authenticated_seller: offer().seller,
      recipient: actor("alice"),
      membership_evidence_ref: "home-verified-membership-1",
      authorization: :host_verified_membership_and_disclosure,
      audience: :members_only
    }

    assert {:ok, envelope} = MemberOffers.private_offer(offer(), context, @now)
    assert envelope.audience == :members_only
    assert envelope.offer.solo_unit_minor == 10_000
    assert hd(envelope.offer.tiers).unit_minor == 9_000
    assert envelope.transport == :requires_private_authenticated_delivery

    assert {:error, :members_only_no_public_projection} =
             MemberOffers.public_projection(offer())

    assert {:error, :unauthorized_member_offer} =
             MemberOffers.private_offer(
               offer(),
               %{context | audience: :public},
               @now
             )

    assert {:error, :unauthorized_member_offer} =
             MemberOffers.private_offer(
               offer(),
               %{
                 context
                 | recipient: "https://outsider.example/actors/not-member",
                   authorization: :unverified
               },
               @now
             )

    assert {:error, :unauthorized_member_offer} =
             MemberOffers.private_offer(
               offer(),
               %{context | authenticated_seller: actor("imposter")},
               @now
             )
  end

  test "pledges unlock purchase choice but do not create optional sealed contracts" do
    {:ok, pledge_quote} =
      G.quote(
        offer(),
        [
          %{
            id: "https://a.example/pledge/1",
            buyer: actor("a"),
            offer_id: offer().id,
            offer_revision: 7,
            quantity: 10,
            max_group_unit_minor: 8_000,
            expires_at: @now + 100
          }
        ],
        @now
      )

    assert pledge_quote.status == :pledged_volume_covered_purchase_option_available
    assert pledge_quote.contracted_quantity == 0
    assert pledge_quote.price_authority == :group_price_offer_requires_checkout_authorization

    assert pledge_quote.purchase_option_available
    assert {:ok, choice} = G.purchase_option(pledge_quote, actor("a"), @now)
    assert choice.checkout == :requires_fresh_membership_stock_and_payment_admission

    assert {:error, :invalid_consents} =
             G.commitment_preview(pledge_quote, %{}, [], @now)

    {:ok, contracted} = Contracted.new(offer(), @now)
    assert {:ok, actual} = Contracted.quote(contracted, @now)
    assert actual.contracted_quantity == 0
    assert actual.unlocked_group_unit_minor == nil
    assert actual.status == :contracted_units_below_minimum
  end

  test "minimum contracted units unlock first lower rate; more contracts unlock deeper tier" do
    {:ok, state} = Contracted.new(offer(), @now)
    state = accepted(state, "a", 2)
    state = accepted(state, "b", 2)

    assert {:ok, before} = Contracted.quote(state, @now)
    assert before.contracted_quantity == 4
    assert before.unlocked_group_unit_minor == nil
    assert before.next_tier.more_units_needed == 1

    state = accepted(state, "c", 1)
    assert {:ok, first} = Contracted.quote(state, @now)
    assert first.contracted_quantity == 5
    assert first.unlocked_group_unit_minor == 9_000
    assert first.unlocked_tier_minimum == 5
    assert first.status == :contracted_threshold_reached_pending_stock_and_payment
    assert Enum.sum(Enum.map(first.members, & &1.savings_minor)) == 5_000

    state = accepted(state, "d", 5, %{max_group_unit_minor: 8_000})
    assert {:ok, second} = Contracted.quote(state, @now)
    assert second.contracted_quantity == 10
    assert second.unlocked_group_unit_minor == 8_000
    assert second.next_tier == nil
    assert second.payment_status == :not_authorized_or_collected
    assert second.inventory_status == :not_reserved
  end

  test "seller seals immutable admitted contract threshold, but no payment is executed" do
    {:ok, state} = Contracted.new(offer(), @now)
    state = accepted(state, "a", 3)
    state = accepted(state, "b", 2)
    {:ok, quote} = Contracted.quote(state, @now)

    seal = %{
      id: "seller-seal-1",
      expected_version: state.version,
      op: :seal,
      expected_quote_hash: quote.quote_hash,
      evidence_ref: "seller-signature-host-verification-required"
    }

    assert {:error, :not_ready_to_seal} =
             Contracted.apply(state, actor("a"), seal, @now)

    assert {:ok, sealed, :accepted} =
             Contracted.apply(state, state.offer.seller, seal, @now)

    assert {:ok, ^sealed, :duplicate} =
             Contracted.apply(sealed, state.offer.seller, seal, @now)

    assert {:ok, sealed_quote} = Contracted.sealed_quote(sealed, @now)
    assert sealed_quote.sealed
    assert sealed_quote.quote_hash == quote.quote_hash
    assert sealed_quote.fulfillment_status == :not_requested

    assert {:error, :campaign_sealed} =
             Contracted.apply(
               sealed,
               actor("c"),
               contract(sealed, "c", 1),
               @now
             )
  end

  test "retraction before sealing drops below threshold and blocks sealing" do
    {:ok, s} = Contracted.new(offer(), @now)
    s = accepted(s, "a", 3)
    s = accepted(s, "b", 2)
    {:ok, ready} = Contracted.quote(s, @now)
    assert ready.unlocked_group_unit_minor == 9_000

    withdrawal = %{
      id: "withdraw-b",
      expected_version: s.version,
      op: :withdraw,
      buyer: actor("b"),
      contract_id: "binding-b-1",
      evidence_ref: "host-must-verify-retraction"
    }

    assert {:error, :unknown_or_unauthorized_contract} =
             Contracted.apply(s, actor("a"), withdrawal, @now)

    assert {:ok, s, :accepted} = Contracted.apply(s, actor("b"), withdrawal, @now)
    assert {:ok, lower} = Contracted.quote(s, @now)
    assert lower.contracted_quantity == 3
    assert lower.unlocked_group_unit_minor == nil
    refute lower.quote_hash == ready.quote_hash

    assert {:error, :not_ready_to_seal} =
             Contracted.apply(
               s,
               s.offer.seller,
               %{
                 id: "seal",
                 expected_version: s.version,
                 op: :seal,
                 expected_quote_hash: ready.quote_hash,
                 evidence_ref: "seller"
               },
               @now
             )
  end

  test "signature reference alone, duplicate buyers and stale admission versions do not count twice" do
    {:ok, s} = Contracted.new(offer(), @now)
    c = contract(s, "a", 4)
    {:ok, s, :accepted} = Contracted.apply(s, actor("a"), c, @now)

    assert {:ok, ^s, :duplicate} = Contracted.apply(s, actor("a"), c, @now)

    assert {:error, :idempotency_conflict} =
             Contracted.apply(s, actor("a"), %{c | quantity: 5}, @now)

    assert {:error, :invalid_or_duplicate_contract} =
             Contracted.apply(
               s,
               actor("b"),
               contract(s, "b", 1, %{contract_id: "binding-a-1"}),
               @now
             )

    assert {:error, :stale_contract_version} =
             Contracted.apply(s, actor("b"), contract(s, "b", 1, %{expected_version: 0}), @now)

    assert {:error, :invalid_or_duplicate_contract} =
             Contracted.apply(s, actor("a"), contract(s, "a", 1, %{id: "another"}), @now)

    assert {:error, :invalid_or_duplicate_contract} =
             Contracted.apply(
               s,
               actor("a"),
               contract(s, "b", 1, %{id: "forged-b"}),
               @now
             )
  end

  test "incompatible maximum price cannot be counted as an affordable contract" do
    {:ok, s} = Contracted.new(offer(), @now)
    s = accepted(s, "a", 5, %{max_group_unit_minor: 8_000})
    assert {:error, :contract_price_ceiling_exceeded} = Contracted.quote(s, @now)

    s = accepted(s, "b", 5, %{max_group_unit_minor: 8_000})
    assert {:ok, q} = Contracted.quote(s, @now)
    assert q.unlocked_group_unit_minor == 8_000
    assert q.contracted_quantity == 10
  end

  test "expired contracts are excluded, and an old signed quote cannot survive a deadline" do
    {:ok, s} = Contracted.new(offer(), @now)
    s = accepted(s, "a", 5, %{expires_at: @now + 10})
    {:ok, q} = Contracted.quote(s, @now)
    assert q.unlocked_group_unit_minor == 9_000

    assert {:ok, expired} = Contracted.quote(s, @now + 10)
    assert expired.contracted_quantity == 0
    assert expired.unlocked_group_unit_minor == nil
    refute expired.quote_hash == q.quote_hash
  end

  test "trusted-owner local command replay is deterministic with stable source revisions" do
    {:ok, initial} = Contracted.new(offer(), @now)
    first = contract(initial, "a", 3)
    {:ok, s1, :accepted} = Contracted.apply(initial, actor("a"), first, @now)
    second = contract(s1, "b", 2)
    {:ok, expected, :accepted} = Contracted.apply(s1, actor("b"), second, @now)

    assert {:ok, ^expected} =
             Contracted.replay(initial, [
               {actor("a"), first, @now},
               {actor("a"), first, @now},
               {actor("b"), second, @now}
             ])

    assert {:error, :invalid_or_duplicate_contract} =
             Contracted.apply(
               expected,
               actor("c"),
               contract(expected, "c", 1, %{offer_revision: 8}),
               @now
             )
  end

  test "no participant-count cap: one hundred admitted member contracts unlock a posted tier" do
    {:ok, state} = Contracted.new(offer(), @now)

    final =
      Enum.reduce(1..100, state, fn n, current ->
        accepted(current, "buyer#{n}", 1)
      end)

    assert {:ok, quote} = Contracted.quote(final, @now)
    assert quote.contracted_quantity == 100
    assert quote.unlocked_group_unit_minor == 8_000
    assert length(quote.members) == 100
  end
end
