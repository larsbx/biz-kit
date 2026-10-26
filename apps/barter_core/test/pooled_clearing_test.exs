defmodule BarterCore.PooledClearingTest do
  use ExUnit.Case, async: true

  alias BarterCore.PooledClearing, as: Clearing
  alias BarterCore.PooledBrokerage, as: Brokerage

  @now 1_800_000_000

  defp asset(code, unit, quantity),
    do: %{code: code, unit: unit, quantity: quantity}

  defp member(name, supplies, needs, revision \\ 1) do
    %{
      actor: "https://#{name}.example/actors/trader",
      revision: revision,
      valid_until: @now + 2_000,
      supplies: supplies,
      needs: needs
    }
  end

  defp charter do
    %{
      company_id: "https://consortium.example/entities/round-1",
      charter_hash: String.duplicate("b", 64),
      version: 1,
      expires_at: @now + 500,
      authority: :matching_and_reconciliation_only,
      title_policy: :retained_by_providers,
      formation: :requires_external_legal_confirmation
    }
  end

  defp fixture do
    [
      member("a", [asset("x", "piece", 7)], [asset("y", "piece", 2)]),
      member("b", [asset("x", "piece", 5)], [asset("y", "piece", 3)]),
      member("c", [asset("y", "piece", 3)], [asset("x", "piece", 8)]),
      member("d", [asset("y", "piece", 2)], [asset("x", "piece", 6)])
    ]
  end

  defp references(draft) do
    Enum.map(draft.members, fn actor ->
      %{actor: actor, agreement_hash: draft.agreement_hash, evidence_ref: "proof-" <> actor}
    end)
  end

  test "exact many-to-many partial allocation per distinct resource; unmet is explicit" do
    assert {:ok, plan} = Clearing.optimize(fixture(), @now)
    assert plan.optimality == :exact_integer_max_flow_per_resource
    assert plan.optimization == :max_units_independently_per_exact_resource
    assert plan.fulfilled_by_asset == [
             %{code: "x", unit: "piece", quantity: 12},
             %{code: "y", unit: "piece", quantity: 5}
           ]
    assert length(plan.participants) == 4

    shipped_x =
      plan.transfers
      |> Enum.filter(&(&1.asset.code == "x"))
      |> Enum.map(& &1.asset.quantity)
      |> Enum.sum()

    assert shipped_x == 12

    assert plan.unmatched_needs
           |> Enum.filter(&(&1.asset.code == "x"))
           |> Enum.map(& &1.asset.quantity)
           |> Enum.sum() == 2

    assert plan.unallocated_supplies == []
    assert {:ok, ^plan} = Clearing.verify_plan(plan, @now)
  end

  test "maximum flow repairs selfish or greedy allocation: only cross-member deliveries" do
    members = [
      member("a", [asset("x", "kg", 4)], [asset("x", "kg", 4)]),
      member("b", [asset("x", "kg", 4)], []),
      member("c", [], [asset("x", "kg", 4)])
    ]

    assert {:ok, plan} = Clearing.optimize(members, @now)
    assert plan.fulfilled_by_asset == [%{code: "x", unit: "kg", quantity: 8}]
    assert Enum.map(plan.transfers, &{&1.from, &1.to}) == [
             {"https://b.example/actors/trader", "https://a.example/actors/trader"},
             {"https://a.example/actors/trader", "https://c.example/actors/trader"}
           ] or
             Enum.sort(Enum.map(plan.transfers, &{&1.from, &1.to})) ==
               Enum.sort([
                 {"https://b.example/actors/trader", "https://a.example/actors/trader"},
                 {"https://a.example/actors/trader", "https://c.example/actors/trader"}
               ])

    assert Enum.all?(plan.transfers, &(&1.from != &1.to))
  end

  test "unbounded topology: fourteen members split supply and demand in one company" do
    providers =
      for index <- 0..6 do
        member("s#{index}", [asset("metal", "kg", 10)], [asset("labor", "h", 1)])
      end

    recipients =
      for index <- 0..6 do
        member("r#{index}", [asset("labor", "h", 1)], [asset("metal", "kg", 10)])
      end

    assert {:ok, plan} = Clearing.optimize(Enum.reverse(providers ++ recipients), @now)
    assert length(plan.participants) == 14
    assert plan.fulfilled_by_asset == [
             %{code: "labor", unit: "h", quantity: 7},
             %{code: "metal", unit: "kg", quantity: 70}
           ]
    assert {:ok, ^plan} = Clearing.optimize(providers ++ recipients, @now)
  end

  test "same actor cannot supply to self even if same resource is advertised both ways" do
    a = member("a", [asset("x", "piece", 5)], [asset("x", "piece", 5)])
    assert {:ok, plan} = Clearing.optimize([a], @now)
    assert plan.transfers == []
    assert plan.participants == []
    assert plan.unmatched_needs == [
             %{actor: a.actor, asset: asset("x", "piece", 5)}
           ]
    assert plan.unallocated_supplies == [
             %{actor: a.actor, asset: asset("x", "piece", 5)}
           ]
  end

  test "different assets and units never mix, even if labels look convertible" do
    list = [
      member("a", [asset("grain", "kg", 2)], []),
      member("b", [], [asset("grain", "g", 2)]),
      member("c", [], [asset("other", "kg", 2)])
    ]

    assert {:ok, plan} = Clearing.optimize(list, @now)
    assert plan.transfers == []
    assert Enum.all?(plan.fulfilled_by_asset, &(&1.quantity == 0))
  end

  test "stale inputs ignored; mutable revisions cannot silently reuse signed plan" do
    [a, b, c, d] = fixture()
    assert {:ok, original} = Clearing.optimize([a, b, c, d], @now)
    assert {:ok, changed} = Clearing.optimize([%{a | revision: 2}, b, c, d], @now)
    refute original.terms_hash == changed.terms_hash

    assert {:error, :invalid_pooled_plan} =
             Clearing.verify_plan(%{original | terms_hash: "wrong"}, @now)

    assert {:ok, expired} = Clearing.optimize([a, %{b | valid_until: @now}, c, d], @now)
    refute expired.terms_hash == original.terms_hash
    assert {:ok, ^original} = Clearing.optimize(Enum.reverse(fixture()), @now)
  end

  test "malformed, duplicated, noninteger and overlarge capacities fail closed" do
    [a, b | _] = fixture()
    assert {:error, :duplicate_member} = Clearing.optimize([a, a], @now)

    assert {:error, :invalid_members} =
             Clearing.optimize([a, Map.put(b, :financial_record, "private")], @now)

    assert {:error, :invalid_members} =
             Clearing.optimize([a, put_in(b.supplies, [asset("x", "piece", 3.5)])], @now)

    assert {:error, :invalid_members} =
             Clearing.optimize([a, %{b | supplies: [asset("x", "kg", 1), asset("x", "kg", 2)]}], @now)

    max = 9_007_199_254_740_991

    overflow = [
      member("a", [asset("x", "kg", max)], []),
      member("b", [asset("x", "kg", max)], [])
    ]

    assert {:error, :quantity_overflow} = Clearing.optimize(overflow, @now)
    assert {:error, :invalid_options} = Clearing.optimize(fixture(), @now, work_budget: -1)
    assert {:error, :work_budget_exceeded} =
             Clearing.optimize(fixture(), @now, work_budget: 1)
  end

  test "temporary company draft and unanimous exact member references remain pre-authority" do
    assert {:ok, plan} = Clearing.optimize(fixture(), @now)
    assert {:ok, draft} = Brokerage.draft(plan, charter(), @now)

    assert draft.members == plan.participants
    assert draft.expires_at == @now + 500
    assert {:ok, preview} = Brokerage.pre_delivery_preview(draft, references(draft), @now)
    assert length(preview.obligations) == length(plan.transfers)
    assert Enum.all?(preview.obligations, &(&1.state == :not_admitted))
    assert preview.status == :requires_signatures_legal_formation_and_local_admission
    assert preview.balancing == :requires_negotiated_consideration_and_member_approval
    refute preview.vehicle_formed
    refute preview.company_takes_title
  end

  test "all-party agreement requires exact charter, roster and terms evidence" do
    assert {:ok, plan} = Clearing.optimize(fixture(), @now)
    assert {:ok, agreement} = Brokerage.draft(plan, charter(), @now)
    witnesses = references(agreement)
    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(agreement, tl(witnesses), @now)

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(
               agreement,
               [hd(witnesses) | Enum.map(tl(witnesses), &%{&1 | evidence_ref: "reuse"})],
               @now
             )

    assert {:ok, updated} = Brokerage.draft(plan, %{charter() | version: 2}, @now)
    refute updated.agreement_hash == agreement.agreement_hash

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(updated, witnesses, @now)

    assert {:error, :invalid_brokerage_draft} =
             Brokerage.draft(plan, %{charter() | authority: :execute_money}, @now)

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(agreement, witnesses, @now + 500)
  end

  test "no automatically formed brokerage for zero viable allocations" do
    member = member("a", [asset("x", "piece", 1)], [asset("x", "piece", 1)])
    assert {:ok, plan} = Clearing.optimize([member], @now)
    assert {:error, :invalid_brokerage_draft} = Brokerage.draft(plan, charter(), @now)
  end
end
