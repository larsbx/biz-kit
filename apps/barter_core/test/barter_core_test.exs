defmodule BarterCoreTest do
  use ExUnit.Case, async: true

  alias BarterCore, as: B
  alias BarterCore.{Agreement, Brokerage}

  @now 1_800_000_000

  defp asset({code, unit, quantity}),
    do: %{code: code, unit: unit, quantity: quantity}

  defp intent(key, provides, needs, revision \\ 1) do
    %{
      id: "https://#{key}.example/barter/1",
      owner: "https://#{key}.example/actors/shop",
      revision: revision,
      valid_until: @now + 1_000,
      provides: asset(provides),
      needs: asset(needs)
    }
  end

  defp pair do
    [
      intent("alpha", {"grain", "kg", 10}, {"milk", "l", 4}),
      intent("beta", {"milk", "l", 6}, {"grain", "kg", 8})
    ]
  end

  defp ring(n) do
    for i <- 0..(n - 1) do
      intent(
        "p#{i}",
        {"good#{i}", "piece", 1},
        {"good#{rem(i + n - 1, n)}", "piece", 1}
      )
    end
  end

  defp charter do
    %{
      company_id: "https://association.example/brokerage/round-42",
      charter_hash: String.duplicate("a", 64),
      version: 1,
      expires_at: @now + 500,
      authority: :matching_and_reconciliation_only,
      title_policy: :retained_by_providers,
      formation: :requires_external_legal_confirmation
    }
  end

  defp consents(draft) do
    Enum.map(draft.members, fn member ->
      %{
        actor: member,
        agreement_hash: draft.agreement_hash,
        evidence_ref: "host-must-verify-" <> member
      }
    end)
  end

  test "bilateral clearing is exact and does not allocate leftover stock" do
    assert {:ok, [route]} = B.routes(pair(), @now)
    assert Enum.map(route.legs, & &1.asset.quantity) == [8, 4]
    assert length(route.participants) == 2
    assert {:ok, ^route} = B.verify_route(route, @now)
    assert route.terms_hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "a three-party nonbrokered delivery circle may be covered by a member broker contract" do
    intents = [
      intent("a", {"wood", "m3", 3}, {"labor", "hour", 5}),
      intent("b", {"transport", "hour", 2}, {"wood", "m3", 2}),
      intent("c", {"labor", "hour", 8}, {"transport", "hour", 1})
    ]

    assert {:ok, plan} = B.optimize(intents, @now)
    assert plan.matched_intents == 3
    assert [route] = plan.cycles
    assert Enum.map(route.legs, & &1.asset.quantity) == [2, 1, 5]

    assert {:ok, draft} = Brokerage.draft(plan, charter(), @now)
    assert length(draft.members) == 3
    assert {:ok, preview} = Brokerage.pre_delivery_preview(draft, consents(draft), @now)
    assert preview.company_takes_title == false
    assert preview.vehicle_status == :unformed_pending_external_legal_confirmation
    assert Enum.all?(preview.obligations, &(&1.status == :not_admitted))
    assert Enum.map(preview.obligations, &{&1.provider, &1.recipient}) == [
             {"https://a.example/actors/shop", "https://b.example/actors/shop"},
             {"https://b.example/actors/shop", "https://c.example/actors/shop"},
             {"https://c.example/actors/shop", "https://a.example/actors/shop"}
           ]
  end

  test "no four-party or sixteen-intent ceiling; a single exact cycle may contain twenty parties" do
    assert {:ok, plan} = B.optimize(Enum.reverse(ring(20)), @now)
    assert plan.matched_intents == 20
    assert length(plan.cycles) == 1
    assert length(hd(plan.cycles).participants) == 20
    assert {:ok, ^plan} = B.verify_plan(plan, @now)
    assert {:ok, [route]} = B.routes(ring(20), @now)
    assert length(route.legs) == 20

    assert {:error, :work_budget_exceeded} =
             B.optimize(ring(20), @now, work_budget: 100)
  end

  test "independent two- and three-person cycles are optimized together" do
    extra = [
      intent("c", {"w", "pc", 1}, {"z", "pc", 1}),
      intent("d", {"x", "pc", 1}, {"w", "pc", 1}),
      intent("e", {"z", "pc", 1}, {"x", "pc", 1}),
      intent("lonely", {"other", "pc", 1}, {"unavailable", "pc", 1})
    ]

    assert {:ok, plan} = B.optimize(pair() ++ extra, @now)
    assert plan.matched_intents == 5
    assert length(plan.cycles) == 2
    assert Enum.map(plan.cycles, &length(&1.intents)) == [2, 3]
    assert length(plan.unmatched) == 1
    assert plan.objective == :max_fulfilled_indivisible_intents
    assert plan.optimality == :exact_for_indivisible_slot_model
    assert {:ok, ^plan} = B.optimize(Enum.reverse(pair() ++ extra), @now)
  end

  test "exact optimum equals exhaustive permutation objective on small overlapping graph" do
    candidates = [
      intent("a", {"x", "piece", 3}, {"z", "piece", 1}),
      intent("b", {"x", "piece", 1}, {"x", "piece", 1}),
      intent("c", {"z", "piece", 1}, {"x", "piece", 1}),
      intent("d", {"x", "piece", 1}, {"x", "piece", 1}),
      intent("e", {"y", "piece", 1}, {"y", "piece", 1})
    ]

    assert {:ok, plan} = B.optimize(candidates, @now)
    all = Enum.sort_by(candidates, & &1.id)
    optimum =
      all
      |> permutations()
      |> Enum.reduce(0, fn matching, best ->
        pairs = Enum.zip(all, matching)

        if Enum.all?(pairs, fn {from, to} ->
             from.id == to.id or B.compatible?(from, to)
           end) do
          served = Enum.count(pairs, fn {from, to} -> from.id != to.id end)
          max(served, best)
        else
          best
        end
      end)

    assert plan.matched_intents == optimum
    assert Enum.sum(Enum.map(plan.cycles, &length(&1.intents))) == optimum
  end

  test "incompatible units, capacity, expiry and same-owner edges do not match" do
    [a, b] = pair()
    assert {:ok, []} = B.routes([a, put_in(b.needs.unit, "g")], @now)
    assert {:ok, []} = B.routes([a, put_in(b.needs.quantity, 11)], @now)
    assert {:ok, []} = B.routes([a, %{b | valid_until: @now}], @now)
    same_owner_b = %{b | id: "https://alpha.example/barter/2", owner: a.owner}
    assert {:ok, []} = B.routes([a, same_owner_b], @now)
  end

  test "duplicate claims, malformed fields and non-integer assets are rejected" do
    [a, b] = pair()
    assert {:error, :duplicate_intent} = B.optimize([a, a], @now)
    assert {:error, :invalid_intents} =
             B.optimize([a, %{b | owner: "https://evil.example/actors/shop"}], @now)
    assert {:error, :invalid_intents} = B.optimize([a, Map.put(b, :email, "secret")], @now)
    assert {:error, :invalid_intents} =
             B.optimize([a, put_in(b.provides.quantity, 1.5)], @now)
    assert {:error, :invalid_options} = B.optimize(pair(), @now, unexpected: true)
  end

  test "brokerage membership cannot be inferred from missing, duplicate or stale consents" do
    assert {:ok, plan} = B.optimize(ring(6), @now)
    assert {:ok, draft} = Brokerage.draft(plan, charter(), @now)
    witnesses = consents(draft)

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(draft, tl(witnesses), @now)

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(draft, [hd(witnesses) | tl(tl(witnesses))], @now)

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(draft,
               [hd(witnesses) | Enum.map(tl(witnesses), fn witness ->
                 %{witness | evidence_ref: hd(witnesses).evidence_ref}
               end)], @now)

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(draft, witnesses, @now + 500)

    assert {:error, :invalid_brokerage_draft} =
             Brokerage.draft(plan, %{charter() | authority: :execute_payments}, @now)
  end

  test "changing terms, charter or direct legs invalidates agreement fingerprints" do
    assert {:ok, plan} = B.optimize(pair(), @now)
    assert {:ok, draft} = Brokerage.draft(plan, charter(), @now)
    assert {:ok, revised} = Brokerage.draft(plan, %{charter() | version: 2}, @now)
    refute draft.agreement_hash == revised.agreement_hash

    assert {:error, :invalid_brokerage_consents} =
             Brokerage.pre_delivery_preview(revised, consents(draft), @now)

    assert {:error, :invalid_plan} =
             B.verify_plan(%{plan | matched_intents: 900}, @now)

    assert {:error, :invalid_route} =
             B.verify_route(
               put_in(hd(plan.cycles), [:legs, Access.at(0), :asset, :quantity], 9),
               @now
             )
  end

  test "old per-route conditional previews remain explicitly unadmitted" do
    assert {:ok, [route]} = B.routes(pair(), @now)
    witnesses =
      Enum.map(route.participants, fn actor ->
        %{actor: actor, terms_hash: route.terms_hash, evidence_ref: actor}
      end)

    assert {:ok, preview} = Agreement.pre_delivery_preview(route, witnesses, @now)
    assert preview.status == :requires_independent_local_admission
    assert Enum.all?(preview.entries, &(&1.state == :not_admitted))
  end

  defp permutations([]), do: [[]]

  defp permutations(xs) do
    for x <- xs, rest <- permutations(List.delete(xs, x)), do: [x | rest]
  end
end
