defmodule CoopSubstrate.NettingExecutionTest do
  @moduledoc """
  Phase 9A (docs/phase9a_plan.md): a netting round executes only when it
  equals the recomputed set-off (closing the pair's like-denominated
  obligations atomically and opening exactly the residual); exposure caps
  bind on charter declaration (bootstrap-then-enforce); rings are visible
  as bare aggregates only; everything recomputes purely from the log.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Finance
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  setup do
    steward = new_member("steward")

    actors =
      Map.new(["M-ada", "M-bob", "M-carol"], fn id ->
        actor = new_member("member")

        {:ok, _} =
          Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))

        {id, actor}
      end)

    %{steward: steward, actors: actors}
  end

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp obligate!(ctx, id, debtor, creditor, amount, denomination \\ "USD") do
    Log.append(
      multi_signed_event(
        [as_role(ctx.actors[debtor], "debtor"), as_role(ctx.actors[creditor], "creditor")],
        "ObligationRecorded",
        %{
          "obligation_id" => id,
          "debtor_id" => debtor,
          "creditor_id" => creditor,
          "amount_minor" => amount,
          "denomination" => denomination
        }
      )
    )
  end

  defp netting_event(ctx, {a, b}, payload) do
    multi_signed_event(
      [as_role(ctx.actors[a], "party_a"), as_role(ctx.actors[b], "party_b")],
      "NettingExecuted",
      Map.merge(%{"party_a" => a, "party_b" => b, "denomination" => "USD"}, payload)
    )
  end

  defp declare!(name, value) do
    author = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(author, "CharterConstantDeclared", %{"name" => name, "value" => value})
      )
  end

  test "a netting round executes only when it equals the recomputed set-off", ctx do
    {:ok, _} = obligate!(ctx, "OB-1", "M-ada", "M-bob", 100)
    {:ok, _} = obligate!(ctx, "OB-2", "M-bob", "M-ada", 60)
    {:ok, _} = obligate!(ctx, "OB-3", "M-ada", "M-bob", 40, "EUR")
    {:ok, _} = obligate!(ctx, "OB-4", "M-ada", "M-carol", 25)

    report = %{"a_to_b" => 100, "b_to_a" => 60, "setoff" => 60}

    residual = %{
      "residual_obligation_id" => "OB-NET-1",
      "net_debtor" => "M-ada",
      "net_creditor" => "M-bob",
      "net_minor" => 40
    }

    # One representation per pair; tampered figures unrepresentable; the
    # residual travels all-or-nothing and must match the net.
    assert {:error, {:reject, _, :pair_not_sorted}} =
             Log.append(
               multi_signed_event(
                 [
                   as_role(ctx.actors["M-bob"], "party_a"),
                   as_role(ctx.actors["M-ada"], "party_b")
                 ],
                 "NettingExecuted",
                 Map.merge(
                   %{"party_a" => "M-bob", "party_b" => "M-ada", "denomination" => "USD"},
                   Map.merge(report, residual)
                 )
               )
             )

    assert {:error, {:reject, _, :netting_mismatch}} =
             Log.append(
               netting_event(
                 ctx,
                 {"M-ada", "M-bob"},
                 Map.merge(%{report | "setoff" => 100}, residual)
               )
             )

    assert {:error, {:reject, _, :residual_mismatch}} =
             Log.append(netting_event(ctx, {"M-ada", "M-bob"}, report))

    assert {:error, {:reject, _, :residual_mismatch}} =
             Log.append(
               netting_event(
                 ctx,
                 {"M-ada", "M-bob"},
                 Map.merge(report, %{residual | "net_minor" => 41})
               )
             )

    {:ok, _} = Log.append(netting_event(ctx, {"M-ada", "M-bob"}, Map.merge(report, residual)))

    # The pair's USD rail now holds only the residual; EUR and the carol
    # pair are untouched.
    assert {:ok, [eur, usd]} = Finance.netting(@chapter, {"M-ada", "M-bob"})
    assert %{denomination: "EUR", a_to_b: 40, setoff: 0} = eur

    assert %{denomination: "USD", a_to_b: 40, b_to_a: 0, setoff: 0, net: {"M-ada", "M-bob", 40}} =
             usd

    assert {:ok, [%{a_to_b: 25}]} = Finance.netting(@chapter, {"M-ada", "M-carol"})

    # A one-way position nets nothing.
    assert {:error, {:reject, _, :nothing_to_net}} =
             Log.append(
               netting_event(ctx, {"M-ada", "M-bob"}, %{
                 "a_to_b" => 40,
                 "b_to_a" => 0,
                 "setoff" => 0
               })
             )

    # A balanced round carries no residual.
    {:ok, _} = obligate!(ctx, "OB-5", "M-bob", "M-ada", 40)

    assert {:error, {:reject, _, :residual_mismatch}} =
             Log.append(
               netting_event(
                 ctx,
                 {"M-ada", "M-bob"},
                 Map.merge(%{"a_to_b" => 40, "b_to_a" => 40, "setoff" => 40}, residual)
               )
             )

    {:ok, _} =
      Log.append(
        netting_event(ctx, {"M-ada", "M-bob"}, %{"a_to_b" => 40, "b_to_a" => 40, "setoff" => 40})
      )

    # Fully netted: nothing open on the USD rail — only the EUR position
    # remains in the report.
    assert {:ok, [%{denomination: "EUR", a_to_b: 40}]} =
             Finance.netting(@chapter, {"M-ada", "M-bob"})

    assert :ok = Log.verify_chains()
  end

  test "exposure caps bind on declaration and netting re-opens headroom", ctx do
    {:ok, _} = obligate!(ctx, "OB-1", "M-ada", "M-bob", 100)

    # Bootstrap: unbounded until a chapter declares its caps.
    {:ok, _} = obligate!(ctx, "OB-2", "M-ada", "M-carol", 1_000_000)
    declare!("finance/borrower_cap_minor", 1_000_150)

    assert {:error, {:reject, _, {:borrower_cap_exceeded, 1_000_150}}} =
             obligate!(ctx, "OB-3", "M-ada", "M-bob", 51)

    {:ok, _} = obligate!(ctx, "OB-3", "M-ada", "M-bob", 50)

    # Funder concentration: bob is owed 150 of a declared 200.
    declare!("finance/funder_cap_minor", 200)

    assert {:error, {:reject, _, {:funder_cap_exceeded, 200}}} =
             obligate!(ctx, "OB-4", "M-carol", "M-bob", 51)

    # Assignment moves exposure: carol at 0 owed... a substitution pushing
    # ada past her borrower cap is rejected; carol can absorb it.
    assert {:error, {:reject, _, {:borrower_cap_exceeded, 1_000_150}}} =
             Log.append(
               multi_signed_event(
                 [
                   as_role(ctx.actors["M-carol"], "assignor"),
                   as_role(ctx.actors["M-ada"], "assignee")
                 ],
                 "ObligationAssigned",
                 %{"obligation_id" => "OB-2", "new_debtor_id" => "M-ada"}
               )
             )

    # Netting execution reduces exposure and re-opens headroom: a
    # counter-obligation makes the pair nettable (ada→bob 150, bob→ada
    # 100), the round leaves only the 50 residual, so bob's funder
    # concentration drops from 250 to 150 and the previously-rejected
    # obligation now fits.
    {:ok, _} = obligate!(ctx, "OB-5", "M-bob", "M-ada", 100)

    {:ok, _} =
      Log.append(
        netting_event(ctx, {"M-ada", "M-bob"}, %{
          "a_to_b" => 150,
          "b_to_a" => 100,
          "setoff" => 100,
          "residual_obligation_id" => "OB-NET-1",
          "net_debtor" => "M-ada",
          "net_creditor" => "M-bob",
          "net_minor" => 50
        })
      )

    {:ok, _} = obligate!(ctx, "OB-4", "M-carol", "M-bob", 51)

    assert :ok = Log.verify_chains()
  end

  test "rings are visible as aggregates only; self-dealing stays unrepresentable", ctx do
    {:ok, _} = obligate!(ctx, "OB-1", "M-ada", "M-bob", 100)
    {:ok, _} = obligate!(ctx, "OB-2", "M-bob", "M-carol", 50)

    # A path is not a ring.
    assert {:ok, %{"USD" => %{rings: 0, gross_minor: 0}}} = Finance.ring_stats(@chapter)

    # Closing the triangle makes exactly one ring carrying all three edges.
    {:ok, _} = obligate!(ctx, "OB-3", "M-carol", "M-ada", 70)

    assert {:ok, %{"USD" => usd}} = Finance.ring_stats(@chapter)
    assert usd == %{rings: 1, gross_minor: 220}

    # The aggregate never carries a member id — pinned structurally.
    assert Enum.sort(Map.keys(usd)) == [:gross_minor, :rings]

    # Self-dealing (1C) still unrepresentable — same key twice dies at
    # envelope construction (:duplicate_key_id), so the gate check is
    # exercised with two keys citing one member.
    assert {:error, {:reject, _, :self_obligation}} =
             Log.append(
               multi_signed_event(
                 [
                   as_role(ctx.actors["M-ada"], "debtor"),
                   as_role(ctx.actors["M-bob"], "creditor")
                 ],
                 "ObligationRecorded",
                 %{
                   "obligation_id" => "OB-9",
                   "debtor_id" => "M-ada",
                   "creditor_id" => "M-ada",
                   "amount_minor" => 10,
                   "denomination" => "USD"
                 }
               )
             )

    # Purity: the same answers from a rebuilt appender.
    restart_log()
    assert {:ok, %{"USD" => ^usd}} = Finance.ring_stats(@chapter)
    assert :ok = Log.verify_chains()
  end
end
