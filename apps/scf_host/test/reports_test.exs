defmodule ScfHost.ReportsTest do
  use ExUnit.Case, async: true

  alias ScfCore.Ledger
  alias ScfHost.Reports

  defp book do
    {:ok, l} =
      Ledger.post(Ledger.new(), %{
        id: "signed-scf-v1:3",
        journal: "OD",
        date: ~D[2026-03-05],
        piece: "S",
        label: "Capital",
        lines: [{:debit, "512", 1_000_00}, {:credit, "101", 1_000_00}]
      })

    {:ok, l} =
      Ledger.post(l, %{
        id: "signed-scf-v1:5",
        journal: "VE",
        date: ~D[2026-04-02],
        piece: "F1",
        label: "Vente",
        lines: [{:debit, "411", 119_00}, {:credit, "706", 100_00}, {:credit, "4457", 19_00}]
      })

    {:ok, l} =
      Ledger.reverse(l, "signed-scf-v1:5", %{
        id: "signed-scf-v1:6",
        date: ~D[2026-04-03],
        piece: "AV"
      })

    %{
      entity_id: "sarl",
      first_year: 2026,
      open_year: 2026,
      ledger: l,
      reversed: MapSet.new([5]),
      postings: %{3 => %{reverses: nil}, 5 => %{reverses: nil}, 6 => %{reverses: %{sequence: 5}}}
    }
  end

  test "journal rows carry their log position, reversal links and totals" do
    assert [capital, sale, reversal] = Reports.journal(book())

    assert %{sequence: 3, reversible: true, reverses: nil, debit: 1_000_00, credit: 1_000_00} =
             capital

    assert %{sequence: 5, reversible: false} = sale
    assert %{sequence: 6, reversible: true, reverses: 5} = reversal
  end

  test "statements default to the open exercice and agree with ScfCore" do
    s = Reports.statements(book(), %{})
    assert s.window == [from: ~D[2026-01-01], to: ~D[2026-12-31]]
    assert s.trial_balance.total_debit == s.trial_balance.total_credit
    assert s.bilan.total_actif == s.bilan.total_passif
    assert s.tcr.resultat_net == 0
    assert s.g50 == %{collectee: 0, deductible: 0, due: 0, credit: 0}
  end

  test "a window is read from du/au or from/to, and a month for the G50" do
    assert Reports.window(%{"du" => "2026-04-01", "au" => "2026-04-02"}, 2026) == [
             from: ~D[2026-04-01],
             to: ~D[2026-04-02]
           ]

    assert Reports.window(%{"from" => "2026-04-01", "to" => "2026-04-30"}, 2026) == [
             from: ~D[2026-04-01],
             to: ~D[2026-04-30]
           ]

    assert Reports.window(%{"mois" => "2026-02"}, 2026) == [
             from: ~D[2026-02-01],
             to: ~D[2026-02-28]
           ]

    assert Reports.window(%{"du" => "garbage"}, 2026) == [
             from: ~D[2026-01-01],
             to: ~D[2026-12-31]
           ]

    april = Reports.statements(book(), %{"du" => "2026-04-02", "au" => "2026-04-02"})
    assert april.g50 == %{collectee: 19_00, deductible: 0, due: 19_00, credit: 0}
  end

  test "JSON form is plain data: ISO dates, integer centimes, string sides" do
    json =
      Reports.to_json(%{
        journal: Reports.journal(book()),
        statements: Reports.statements(book(), %{})
      })

    assert {:ok, encoded} = Jason.encode(json)
    assert encoded =~ ~s("date":"2026-03-05")
    assert encoded =~ ~s("side":"debit")
  end
end
