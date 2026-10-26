defmodule GroupBuyCore.EscrowTest do
  use ExUnit.Case, async: true

  alias GroupBuyCore.BindingRound
  alias GroupBuyCore.Escrow

  @now 1_800_000_000
  @provider "qualified-provider-1"
  @provider_actor {:custody_provider, @provider}

  defp offer do
    %{
      id: "https://seller.example/group-buys/parts",
      seller: "https://seller.example/actors/merchant",
      sku: "parts",
      unit: "piece",
      currency: "USD",
      revision: 3,
      expires_at: @now + 1_000,
      capacity: 40,
      solo_unit_minor: 10_000,
      tiers: [
        %{min_quantity: 5, unit_minor: 9_000},
        %{min_quantity: 10, unit_minor: 8_000}
      ]
    }
  end

  defp actor(name), do: "https://#{name}.example/actors/buyer"

  defp pledge(name, qty) do
    %{
      id: "https://#{name}.example/pledge/1",
      buyer: actor(name),
      offer_id: offer().id,
      offer_revision: 3,
      quantity: qty,
      max_group_unit_minor: 9_000,
      expires_at: @now + 200
    }
  end

  defp admit(round, name, quantity) do
    command = %{
      id: "pledge-command-#{name}",
      expected_version: round.version,
      op: :pledge,
      pledge: pledge(name, quantity),
      evidence_ref: "host-verifies-binding-consent-#{name}"
    }

    {:ok, next, :accepted} = BindingRound.apply(round, actor(name), command, @now)
    next
  end

  defp funded(state, round, name, quantity, overrides \\ %{}) do
    cmd =
      Map.merge(
        %{
          id: "escrow-fund-#{name}",
          expected_version: state.version,
          op: :hold_confirmed,
          buyer: actor(name),
          pledge_id: pledge(name, quantity).id,
          provider_id: @provider,
          custody_ref: "custody-unique-#{name}",
          currency: "USD",
          amount_minor: quantity * 9_000,
          expires_at: @now + 2_000,
          evidence_ref: "externally-confirmed-funds-#{name}"
        },
        overrides
      )

    {:ok, next, :accepted} = Escrow.apply(state, round, @provider_actor, cmd, @now)
    {next, cmd}
  end

  defp round_with_three_and_two do
    {:ok, initial} = BindingRound.new(offer(), @now)
    initial |> admit("a", 3) |> admit("b", 2)
  end

  defp funded_round do
    round = round_with_three_and_two()
    {:ok, initial} = Escrow.new(offer(), @now)
    {secured, _a} = funded(initial, round, "a", 3)
    {secured, _b} = funded(secured, round, "b", 2)
    {round, secured}
  end

  defp release(state, name, qty, unit_price \\ 9_000) do
    protected_minor = qty * 9_000
    payout = qty * unit_price

    %{
      id: "provider-release-#{name}",
      expected_version: state.version,
      op: :delivery_release_confirmed,
      buyer: actor(name),
      provider_id: @provider,
      custody_ref: "custody-unique-#{name}",
      settlement_ref: "settled-by-custodian-#{name}",
      delivery_proof_ref: "verified-delivery-provider-or-dispatch-#{name}",
      seller_paid_minor: payout,
      buyer_refund_minor: protected_minor - payout,
      evidence_ref: "provider-signed-settlement-#{name}"
    }
  end

  test "a binding threshold never implies escrow-secured settlement without verified holds" do
    round = round_with_three_and_two()
    {:ok, escrow} = Escrow.new(offer(), @now)
    assert {:error, :escrow_coverage_incomplete} = Escrow.coverage(escrow, round, @now)

    {escrow, _} = funded(escrow, round, "a", 3)
    assert {:error, :escrow_coverage_incomplete} = Escrow.coverage(escrow, round, @now)

    {escrow, _} = funded(escrow, round, "b", 2)
    assert {:ok, coverage} = Escrow.coverage(escrow, round, @now)
    assert coverage.buyers == 2
    assert coverage.committed_units == 5
    assert coverage.secured_minor == 45_000
    assert coverage.current_group_due_minor == 45_000
    assert coverage.custody == :external_provider_not_biz_kit
    assert coverage.seller_release == :blocked_until_verified_delivery_and_provider_confirmation
  end

  test "verified delivery and provider receipt release seller funds exactly once" do
    {round, escrow} = funded_round()
    assert {:ok, preview} = Escrow.settlement_preview(escrow, round, actor("a"), @now)
    assert preview.seller_due_minor == 27_000
    assert preview.buyer_surplus_refund_minor == 0
    assert preview.company_custody == false

    cmd = release(escrow, "a", 3)

    assert {:ok, changed, :accepted} =
             Escrow.apply(escrow, round, @provider_actor, cmd, @now)

    assert changed.positions[actor("a")].status == :released
    assert changed.positions[actor("a")].disposition.seller_minor == 27_000

    assert {:ok, ^changed, :duplicate} =
             Escrow.apply(changed, round, @provider_actor, cmd, @now)

    assert {:error, :release_requires_binding_funding_and_verified_delivery} =
             Escrow.apply(
               changed,
               round,
               @provider_actor,
               %{release(changed, "a", 3) | id: "replay-different"},
               @now
             )

    assert {:error, :idempotency_conflict} =
             Escrow.apply(changed, round, @provider_actor, %{cmd | seller_paid_minor: 1}, @now)
  end

  test "deeper posted tier returns unused protected funds instead of granting seller a windfall" do
    {round, escrow} = funded_round()
    round = admit(round, "c", 5)
    {escrow, _} = funded(escrow, round, "c", 5)

    assert {:ok, ready} = Escrow.coverage(escrow, round, @now)
    assert ready.current_group_due_minor == 80_000
    assert ready.secured_minor == 90_000

    assert {:ok, first} = Escrow.settlement_preview(escrow, round, actor("a"), @now)
    assert first.seller_due_minor == 24_000
    assert first.buyer_surplus_refund_minor == 3_000

    assert {:error, :release_requires_binding_funding_and_verified_delivery} =
             Escrow.apply(
               escrow,
               round,
               @provider_actor,
               release(escrow, "a", 3, 9_000),
               @now
             )

    assert {:ok, updated, :accepted} =
             Escrow.apply(escrow, round, @provider_actor, release(escrow, "a", 3, 8_000), @now)

    assert updated.positions[actor("a")].disposition.buyer_refund_minor == 3_000
    assert updated.positions[actor("a")].disposition.seller_minor == 24_000
  end

  test "failed prethreshold campaign allows full provider-confirmed refund after deadline" do
    {:ok, initial} = BindingRound.new(offer(), @now)
    round = admit(initial, "a", 4)
    {:ok, escrow} = Escrow.new(offer(), @now)
    {escrow, _} = funded(escrow, round, "a", 4)

    refund = %{
      id: "provider-refund-a",
      expected_version: escrow.version,
      op: :refund_confirmed,
      buyer: actor("a"),
      provider_id: @provider,
      custody_ref: "custody-unique-a",
      refund_ref: "custodian-refund-receipt-a",
      refund_minor: 36_000,
      reason: :threshold_failed,
      resolution_ref: nil,
      evidence_ref: "provider-signed-refund"
    }

    assert {:error, :refund_requires_failed_threshold_or_lawful_resolution} =
             Escrow.apply(escrow, round, @provider_actor, refund, @now)

    assert {:ok, changed, :accepted} =
             Escrow.apply(escrow, round, @provider_actor, refund, @now + 1_000)

    assert changed.positions[actor("a")].status == :refunded
    assert changed.positions[actor("a")].disposition.buyer_refund_minor == 36_000

    assert {:error, :refund_requires_failed_threshold_or_lawful_resolution} =
             Escrow.apply(
               changed,
               round,
               @provider_actor,
               %{refund | id: "second-refund", expected_version: changed.version},
               @now + 1_001
             )
  end

  test "postthreshold dispute freezes release until independently verified lawful resolution" do
    {round, escrow} = funded_round()

    dispute = %{
      id: "dispute-a",
      expected_version: escrow.version,
      op: :dispute_open,
      buyer: actor("a"),
      reason_ref: "verified-damage-claim"
    }

    assert {:ok, held, :accepted} =
             Escrow.apply(escrow, round, actor("a"), dispute, @now)

    assert held.positions[actor("a")].status == :disputed

    assert {:error, :release_requires_binding_funding_and_verified_delivery} =
             Escrow.apply(held, round, @provider_actor, release(held, "a", 3), @now)

    refund = %{
      id: "adjudicated-refund-a",
      expected_version: held.version,
      op: :refund_confirmed,
      buyer: actor("a"),
      provider_id: @provider,
      custody_ref: "custody-unique-a",
      refund_ref: "provider-refund-dispute-a",
      refund_minor: 27_000,
      reason: :lawful_resolution,
      resolution_ref: "external-arbitrator-order-a",
      evidence_ref: "provider-signed-refund-a"
    }

    assert {:ok, changed, :accepted} =
             Escrow.apply(held, round, @provider_actor, refund, @now)

    assert changed.positions[actor("a")].status == :refunded
    assert {:error, :escrow_coverage_incomplete} = Escrow.coverage(changed, round, @now)
  end

  test "reused custody reference, wrong provider, unpledged buyer and mismatched money refuse" do
    round = round_with_three_and_two()
    {:ok, escrow} = Escrow.new(offer(), @now)
    {escrow, _} = funded(escrow, round, "a", 3)

    [duplicate_ref, wrong_total, wrong_currency, wrong_pledge] = [
      %{custody_ref: "custody-unique-a"},
      %{amount_minor: 7_000},
      %{currency: "EUR"},
      %{pledge_id: "forged-pledge"}
    ]

    for attrs <- [duplicate_ref, wrong_total, wrong_currency, wrong_pledge] do
      cmd =
        Map.merge(
          %{
            id: "new-b",
            expected_version: escrow.version,
            op: :hold_confirmed,
            buyer: actor("b"),
            pledge_id: pledge("b", 2).id,
            provider_id: @provider,
            custody_ref: "custody-unique-b",
            currency: "USD",
            amount_minor: 18_000,
            expires_at: @now + 2_000,
            evidence_ref: "provider-confirmed"
          },
          attrs
        )

      assert {:error, :invalid_or_duplicate_external_hold} =
               Escrow.apply(escrow, round, @provider_actor, cmd, @now)
    end

    cmd = %{
      id: "new-b",
      expected_version: escrow.version,
      op: :hold_confirmed,
      buyer: actor("b"),
      pledge_id: pledge("b", 2).id,
      provider_id: @provider,
      custody_ref: "custody-unique-b",
      currency: "USD",
      amount_minor: 18_000,
      expires_at: @now + 2_000,
      evidence_ref: "provider-confirmed"
    }

    assert {:error, :invalid_or_duplicate_external_hold} =
             Escrow.apply(escrow, round, {:custody_provider, "imposter"}, cmd, @now)

    assert {:ok, _, :accepted} = Escrow.apply(escrow, round, @provider_actor, cmd, @now)
  end

  test "funding cannot be assumed for pretrigger expired pledges, and funding expiry blocks coverage" do
    {:ok, initial} = BindingRound.new(offer(), @now)
    round = admit(initial, "a", 4)
    {:ok, escrow} = Escrow.new(offer(), @now)

    cmd = %{
      id: "fund-a",
      expected_version: 0,
      op: :hold_confirmed,
      buyer: actor("a"),
      pledge_id: pledge("a", 4).id,
      provider_id: @provider,
      custody_ref: "custody-a",
      currency: "USD",
      amount_minor: 36_000,
      expires_at: @now + 2_000,
      evidence_ref: "provider-confirmation"
    }

    assert {:error, :invalid_or_duplicate_external_hold} =
             Escrow.apply(escrow, round, @provider_actor, cmd, @now + 200)

    {round, _} = {admit(round, "b", 1), nil}

    assert {:ok, %{status: :binding_threshold_activated}} =
             BindingRound.snapshot(round, @now)

    assert {:error, :escrow_coverage_incomplete} =
             Escrow.coverage(escrow, round, @now)
  end
end
