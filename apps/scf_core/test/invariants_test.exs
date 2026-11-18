defmodule ScfCore.InvariantsTest do
  @moduledoc """
  For every finite sequence of admitted entries E₁ … Eₙ over the chart:

    (I1) Σ débit = Σ crédit                       (balance générale)
    (I2) total actif = total passif               (bilan)
    (I3) TCR résultat net = Σ₇ (c − d) − Σ₆ (d − c)
    (I4) balances are invariant under permutation of the postings
    (I5) posting Eᵢ then its contrepassation leaves the balances unchanged
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ScfCore.{Ledger, Statements}

  @accounts ~w(101 106 110 120 131 164 17 211 218 23 281 30 31 39 355 401 404 411 421 431
               444 4456 4457 447 46 512 519 53 600 61 62 63 64 65 66 67 681 695 700 706
               72 73 74 75 76 77 78)

  defp entry_gen do
    gen all(
          debits <-
            list_of({member_of(@accounts), integer(1..10_000_000)}, min_length: 1, max_length: 3),
          credit_accounts <- list_of(member_of(@accounts), min_length: 1, max_length: 3),
          day <- integer(1..365)
        ) do
      total = debits |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      %{
        journal: "OD",
        date: Date.add(~D[2025-12-31], day),
        piece: "P",
        label: "x",
        lines: Enum.map(debits, fn {a, m} -> {:debit, a, m} end) ++ split(credit_accounts, total)
      }
    end
  end

  # Splits `total` across the credit accounts; every part stays ≥ 1.
  defp split([a], total), do: [{:credit, a, total}]

  defp split([a | rest], total) when total > length(rest),
    do: [{:credit, a, 1} | split(rest, total - 1)]

  defp split([a | _], total), do: [{:credit, a, total}]

  # Posts each entry under its index as id; every generated entry is admissible.
  defp ledger(indexed) do
    Enum.reduce(indexed, Ledger.new(), fn {a, i}, l ->
      {:ok, l} = Ledger.post(l, Map.put(a, :id, "e#{i}"))
      l
    end)
  end

  defp ledger_of(entries), do: entries |> Enum.with_index() |> ledger()

  property "I1–I3 hold for every admitted ledger" do
    check all(entries <- list_of(entry_gen(), max_length: 30)) do
      l = ledger_of(entries)
      tb = Ledger.trial_balance(l)
      assert tb.total_debit == tb.total_credit

      b = Statements.bilan(l)
      assert b.total_actif == b.total_passif

      by_class = fn c ->
        for({a, s} <- Ledger.balances(l), ScfCore.Chart.class(a) == c, do: s) |> Enum.sum()
      end

      assert Statements.tcr(l).resultat_net == -by_class.(7) - by_class.(6)
    end
  end

  property "I4 balances are order-independent" do
    check all(entries <- list_of(entry_gen(), max_length: 15), seed <- integer()) do
      indexed = Enum.with_index(entries)
      :rand.seed(:exsss, seed)
      assert Ledger.balances(ledger(indexed)) == Ledger.balances(ledger(Enum.shuffle(indexed)))
    end
  end

  property "I5 contrepassation is an inverse" do
    check all(base <- list_of(entry_gen(), max_length: 10), e <- entry_gen()) do
      l0 = ledger_of(base)
      {:ok, l1} = Ledger.post(l0, Map.put(e, :id, "x"))
      {:ok, l2} = Ledger.reverse(l1, "x", %{id: "xR", date: e.date, piece: "AV"})
      assert Ledger.balances(l2) == Ledger.balances(l0)
    end
  end
end
