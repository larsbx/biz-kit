defmodule GroupBuyCore.BindingRoundTest do
  use ExUnit.Case, async: true

  alias GroupBuyCore.BindingRound, as: Round

  @now 1_800_000_000

  defp offer do
    %{
      id: "https://seller.example/group-buys/parts",
      seller: "https://seller.example/actors/merchant",
      sku: "parts",
      unit: "piece",
      currency: "USD",
      revision: 3,
      expires_at: @now + 1_000,
      capacity: 30,
      solo_unit_minor: 10_000,
      tiers: [
        %{min_quantity: 5, unit_minor: 9_000},
        %{min_quantity: 10, unit_minor: 8_000}
      ]
    }
  end

  defp buyer(name), do: "https://#{name}.example/actors/buyer"

  defp pledge(name, amount, opts \\ %{}) do
    Map.merge(
      %{
        id: "https://#{name}.example/pledge/1",
        buyer: buyer(name),
        offer_id: offer().id,
        offer_revision: 3,
        quantity: amount,
        max_group_unit_minor: 9_000,
        expires_at: @now + 100
      },
      opts
    )
  end

  defp submit(state, name, amount, now \\ @now, opts \\ %{}) do
    p = pledge(name, amount, opts)

    cmd = %{
      id: "submit-#{name}-#{state.version}",
      op: :pledge,
      expected_version: state.version,
      pledge: p,
      evidence_ref: "seller-home-must-verify-signed-conditional-pledge-#{name}"
    }

    {:ok, next, :accepted} = Round.apply(state, buyer(name), cmd, now)
    {next, cmd}
  end

  test "under minimum, signed pledges remain conditional without payment" do
    {:ok, initial} = Round.new(offer(), @now)
    {state, _} = submit(initial, "a", 2)
    {state, _} = submit(state, "b", 2)

    assert {:ok, view} = Round.snapshot(state, @now)
    assert view.status == :conditional_not_yet_binding
    assert view.pledged_quantity == 4
    assert view.minimum == 5
    assert view.additional_units_needed == 1
    assert view.bound_obligations == []
    assert view.payment_status == :not_collected
  end

  test "crossing five units binds ALL pledgers atomically, without another buy click" do
    {:ok, initial} = Round.new(offer(), @now)
    {state, first_cmd} = submit(initial, "a", 2)
    {state, trigger_cmd} = submit(state, "b", 3)

    assert state.activated.at == @now
    assert {:ok, bound} = Round.snapshot(state, @now)
    assert bound.status == :binding_threshold_activated
    assert bound.contracted_quantity == 5
    assert bound.tier_minimum == 5
    assert bound.group_unit_minor == 9_000
    assert bound.total_due_minor == 45_000
    assert Enum.map(bound.members, &{&1.quantity, &1.due_minor}) == [{2, 18_000}, {3, 27_000}]
    assert Enum.all?(bound.members, &(&1.obligation == :binding_automatically_at_threshold))
    assert bound.payment_status == :not_collected
    assert bound.stock_status == :not_reserved

    assert {:ok, ^state, :duplicate} = Round.apply(state, buyer("b"), trigger_cmd, @now)

    assert {:ok, ^state} =
             Round.replay(initial, [
               {buyer("a"), first_cmd, @now},
               {buyer("b"), trigger_cmd, @now}
             ])
  end

  test "withdrawal is allowed before trigger but forbidden once pledges bind" do
    {:ok, initial} = Round.new(offer(), @now)
    {state, _} = submit(initial, "a", 3)
    {state, _} = submit(state, "b", 1)

    withdraw = %{
      id: "withdraw-a",
      expected_version: state.version,
      op: :withdraw,
      buyer: buyer("a"),
      pledge_id: pledge("a", 3).id,
      evidence_ref: "host-authorized-prethreshold-withdrawal"
    }

    assert {:error, :unknown_or_unauthorized_pledge} =
             Round.apply(state, buyer("b"), withdraw, @now)

    assert {:ok, reduced, :accepted} = Round.apply(state, buyer("a"), withdraw, @now)
    assert {:ok, small} = Round.snapshot(reduced, @now)
    assert small.pledged_quantity == 1
    assert small.status == :conditional_not_yet_binding

    {bound, _} = submit(state, "c", 1)

    assert {:error, :binding_pledge_cannot_be_withdrawn} =
             Round.apply(
               bound,
               buyer("a"),
               %{withdraw | expected_version: bound.version},
               @now
             )
  end

  test "joining an already binding round is immediately binding and can only lower prices" do
    {:ok, initial} = Round.new(offer(), @now)
    {state, _} = submit(initial, "a", 2)
    {state, _} = submit(state, "b", 3)
    {:ok, before} = Round.snapshot(state, @now)
    assert before.group_unit_minor == 9_000

    {state, _} = submit(state, "c", 5)
    assert {:ok, after_join} = Round.snapshot(state, @now)
    assert after_join.contracted_quantity == 10
    assert after_join.group_unit_minor == 8_000
    assert after_join.total_due_minor == 80_000
    assert Enum.all?(after_join.members, &(&1.obligation == :binding_automatically_at_threshold))
    assert after_join.threshold_crossed_at == before.threshold_crossed_at
    refute after_join.terms_hash == before.terms_hash
  end

  test "binding survives pledge deadline; no retroactive free withdrawal" do
    {:ok, initial} = Round.new(offer(), @now)
    {state, _} = submit(initial, "a", 5)

    assert {:ok, before} = Round.snapshot(state, @now)
    assert {:ok, after_deadline} = Round.snapshot(state, @now + 500)
    assert after_deadline.contracted_quantity == 5
    assert after_deadline.total_due_minor == before.total_due_minor
    assert after_deadline.terms_hash == before.terms_hash

    assert {:ok, after_campaign} = Round.snapshot(state, @now + 1_001)
    assert after_campaign.offer_expired
    assert after_campaign.total_due_minor == before.total_due_minor
  end

  test "untriggered expired pledges are excluded and can be renewed by the same buyer" do
    {:ok, initial} = Round.new(offer(), @now)
    {state, _} = submit(initial, "a", 4)

    assert {:ok, expired} = Round.snapshot(state, @now + 100)
    assert expired.pledged_quantity == 0
    assert expired.status == :conditional_not_yet_binding

    {state, _} =
      submit(state, "a", 3, @now + 101, %{
        id: "https://a.example/pledge/2",
        expires_at: @now + 500
      })

    {state, _} = submit(state, "b", 2, @now + 101, %{expires_at: @now + 500})
    assert {:ok, bound} = Round.snapshot(state, @now + 101)
    assert bound.contracted_quantity == 5
  end

  test "price ceilings below first activation tier cannot create surprise obligations" do
    {:ok, state} = Round.new(offer(), @now)

    command = %{
      id: "bad-ceiling",
      expected_version: state.version,
      op: :pledge,
      pledge: pledge("a", 5, %{max_group_unit_minor: 8_000}),
      evidence_ref: "host-verified"
    }

    assert {:error, :price_ceiling_below_activation_tier} =
             Round.apply(state, buyer("a"), command, @now)

    assert {:ok, snap} = Round.snapshot(state, @now)
    assert snap.pledged_quantity == 0
  end

  test "scope spoofing, old revision and duplicate IDs cannot bind a member" do
    {:ok, state} = Round.new(offer(), @now)

    c = %{
      id: "command-a",
      expected_version: 0,
      op: :pledge,
      pledge: pledge("a", 3),
      evidence_ref: "host-verified"
    }

    assert {:error, :unauthorized_or_expired_pledge} =
             Round.apply(state, buyer("b"), c, @now)

    assert {:ok, state, :accepted} = Round.apply(state, buyer("a"), c, @now)

    assert {:error, :idempotency_conflict} =
             Round.apply(state, buyer("a"), %{c | pledge: pledge("a", 4)}, @now)

    assert {:error, :stale_binding_version} =
             Round.apply(
               state,
               buyer("b"),
               %{c | id: "stale", pledge: pledge("b", 2)},
               @now
             )

    assert {:error, :invalid_pledges} =
             Round.apply(
               state,
               buyer("b"),
               %{
                 c
                 | id: "wrong-offer",
                   expected_version: state.version,
                   pledge: pledge("b", 2, %{offer_revision: 4})
               },
               @now
             )
  end

  test "no arbitrary four-member cap and deeper tier may activate immediately" do
    {:ok, initial} = Round.new(offer(), @now)
    # Ten units from one authenticated member jump directly to the deepest
    # seller-posted tier before a lower-priced binding transition.
    {state, _} = submit(initial, "a", 10)
    assert {:ok, deep} = Round.snapshot(state, @now)
    assert deep.tier_minimum == 10
    assert deep.group_unit_minor == 8_000

    {:ok, initial} = Round.new(offer(), @now)

    final =
      Enum.reduce(1..15, initial, fn i, current ->
        {next, _} = submit(current, "member#{i}", 1)
        next
      end)

    assert {:ok, multi} = Round.snapshot(final, @now)
    assert multi.contracted_quantity == 15
    assert length(multi.members) == 15
    assert multi.group_unit_minor == 8_000
  end
end
