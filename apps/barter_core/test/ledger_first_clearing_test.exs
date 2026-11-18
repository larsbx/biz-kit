defmodule BarterCore.LedgerFirstClearingTest do
  use ExUnit.Case, async: true

  alias BarterCore.LedgerFirstClearing, as: Clearing

  @now 1_800_000_000

  defp actor(name), do: "https://#{name}.example/actors/merchant"

  defp debt(id, from, to, amount, currency \\ "USD") do
    %{
      id: "https://a.example/obligations/#{id}",
      debtor: actor(from),
      creditor: actor(to),
      amount_minor: amount,
      currency: currency,
      revision: 1,
      evidence_ref: "host-evidence-#{id}",
      valid_until: @now + 1000,
      status: :host_declared_eligible
    }
  end

  test "three-party clearing generates conserved, balanced, unadmitted journal intents" do
    inputs = [
      debt("ab", "a", "b", 100),
      debt("bc", "b", "c", 80),
      debt("ca", "c", "a", 60)
    ]

    assert {:ok, plan} = Clearing.propose(inputs, @now)
    assert plan.original_minor == 240
    assert plan.proposed_reduction_minor == 180
    assert plan.residual_minor == 60
    assert Enum.map(plan.residuals, & &1.amount_minor) == [40, 20]
    assert length(plan.cycles) == 1
    assert hd(plan.cycles).amount_minor == 60
    assert length(plan.journal_intents) == 12
    assert plan.status == :unadmitted_preview_only
    assert plan.authority == :host_assertions_unverified
    assert plan.discharge == :requires_contract_consent_and_legal_effect
    assert plan.financial_settlement == :none
    assert plan.optimization == :deterministic_cycle_heuristic_not_global_optimum

    for {{actor, currency}, postings} <-
          Enum.group_by(plan.journal_intents, &{&1.actor, &1.currency}) do
      assert is_binary(actor) and currency == "USD"

      debit = postings |> Enum.filter(&(&1.side == :debit)) |> Enum.sum_by(& &1.amount_minor)
      credit = postings |> Enum.filter(&(&1.side == :credit)) |> Enum.sum_by(& &1.amount_minor)
      assert debit == credit
      assert Enum.all?(postings, &(&1.status == :unadmitted_preview))

      clearing_debit =
        postings
        |> Enum.filter(&(&1.account == :clearing_control and &1.side == :debit))
        |> Enum.sum_by(& &1.amount_minor)

      clearing_credit =
        postings
        |> Enum.filter(&(&1.account == :clearing_control and &1.side == :credit))
        |> Enum.sum_by(& &1.amount_minor)

      assert clearing_debit == clearing_credit
    end

    assert {:ok, ^plan} = Clearing.verify_plan(plan, @now)
    assert {:ok, ^plan} = Clearing.propose(Enum.reverse(inputs), @now)
  end

  test "mutual setoff reduces reciprocal obligations without pretending to pay cash" do
    assert {:ok, plan} =
             Clearing.propose([debt("ab", "a", "b", 10_000), debt("ba", "b", "a", 7_000)], @now)

    assert plan.proposed_reduction_minor == 14_000
    assert plan.residual_minor == 3_000
    assert length(plan.cycles) == 1
    assert plan.financial_settlement == :none
  end

  test "no cycles: every claim remains and no fabricated ledger entries appear" do
    assert {:ok, plan} =
             Clearing.propose([debt("ab", "a", "b", 20), debt("bc", "b", "c", 10)], @now)

    assert plan.cycles == []
    assert plan.journal_intents == []
    assert plan.original_minor == plan.residual_minor
    assert plan.proposed_reduction_minor == 0
  end

  test "no FX, even when an apparent cycle crosses currencies" do
    input = [
      debt("ab", "a", "b", 100, "USD"),
      debt("ba", "b", "a", 100, "EUR")
    ]

    assert {:ok, plan} = Clearing.propose(input, @now)
    assert plan.cycles == []
    assert plan.original_minor == nil
    assert plan.residual_minor == nil
    assert plan.totals_scope == :per_currency_no_fx

    assert plan.totals_by_currency == [
             %{
               currency: "EUR",
               original_minor: 100,
               proposed_reduction_minor: 0,
               residual_minor: 100
             },
             %{
               currency: "USD",
               original_minor: 100,
               proposed_reduction_minor: 0,
               residual_minor: 100
             }
           ]

    assert {:ok, ^plan} = Clearing.verify_plan(plan, @now)
  end

  test "snapshot, journals and graph are bound against tampering" do
    input = [
      debt("ab", "a", "b", 100),
      debt("ba", "b", "a", 80)
    ]

    assert {:ok, plan} = Clearing.propose(input, @now)

    assert {:error, :invalid_clearing_plan} =
             Clearing.verify_plan(%{plan | proposed_reduction_minor: 100}, @now)

    assert {:error, :invalid_clearing_plan} =
             Clearing.verify_plan(%{plan | journal_intents: []}, @now)

    assert {:error, :invalid_clearing_plan} =
             Clearing.verify_plan(%{plan | cycles: []}, @now)

    assert {:error, :invalid_clearing_plan} =
             Clearing.verify_plan(%{plan | terms_hash: "different"}, @now)

    assert {:ok, changed} =
             Clearing.propose([%{hd(input) | revision: 2}, List.last(input)], @now)

    refute changed.terms_hash == plan.terms_hash
  end

  test "refuses duplicates, self-debts, stale claims, missing evidence, fake approval and floats" do
    a = debt("ab", "a", "b", 10)
    assert {:error, :duplicate_obligation} = Clearing.propose([a, a], @now)

    for invalid <- [
          %{a | debtor: a.creditor},
          %{a | status: :settled},
          %{a | evidence_ref: ""},
          %{a | amount_minor: 1.5},
          %{a | valid_until: @now},
          Map.put(a, :platform_may_execute, true)
        ] do
      assert {:error, :invalid_obligations} = Clearing.propose([invalid], @now)
    end
  end

  test "overflow and bounded computational work fail closed" do
    max = 9_007_199_254_740_991

    assert {:error, :amount_overflow} =
             Clearing.propose([debt("ab", "a", "b", max), debt("bc", "b", "c", 1)], @now)

    assert {:error, :invalid_options} =
             Clearing.propose([debt("ab", "a", "b", 2)], @now, work_budget: 0)

    assert {:error, :work_budget_exceeded} =
             Clearing.propose([debt("ab", "a", "b", 2), debt("bc", "b", "c", 2)], @now,
               work_budget: 1
             )
  end
end
