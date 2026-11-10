defmodule ScfCoreTest do
  use ExUnit.Case, async: true

  alias ScfCore.{Chart, Entry, Ledger, Money, Statements, Tva}

  @d ~D[2026-03-05]

  defp entry(id, lines, overrides \\ %{}) do
    Map.merge(
      %{id: id, journal: "OD", date: @d, piece: "P-#{id}", label: "e#{id}", lines: lines},
      overrides
    )
  end

  defp post!(ledger, attrs) do
    {:ok, ledger} = Ledger.post(ledger, attrs)
    ledger
  end

  describe "Chart (nomenclature SCF, classes 1–7)" do
    test "accepts headline accounts and their sub-accounts" do
      assert Chart.account?("411")
      assert Chart.account?("41100012")
      assert Chart.account?("4457")
      assert Chart.label("4111") == "Clients"
      assert Chart.label("4457") == "Taxes sur le chiffre d'affaires collectées"
      assert Chart.class("706") == 7
    end

    test "rejects unknown prefixes, classes 8–9 and non-digits" do
      refute Chart.account?("79")
      refute Chart.account?("801")
      refute Chart.account?("9")
      refute Chart.account?("41A")
      refute Chart.account?("4")
      refute Chart.account?(411)
    end
  end

  describe "Entry (écriture)" do
    test "a balanced entry with a supporting document is admitted" do
      assert {:ok, %Entry{}} =
               Entry.new(entry("1", [{:debit, "512", 100_00}, {:credit, "101", 100_00}]))
    end

    test "every violation is reported at once" do
      assert {:error, errors} =
               Entry.new(%{
                 id: "",
                 journal: "od",
                 date: "2026",
                 piece: "",
                 lines: [{:debit, "999", 0}]
               })

      assert :missing_id in errors
      assert :missing_piece in errors
      assert :invalid_journal in errors
      assert :invalid_date in errors
      assert :fewer_than_two_lines in errors
      assert {:invalid_account, "999"} in errors
      assert {:non_positive_amount, "999"} in errors
    end

    test "Σ débit ≠ Σ crédit is refused" do
      assert {:error, [{:unbalanced, 100_00, 99_99}]} =
               Entry.new(entry("1", [{:debit, "512", 100_00}, {:credit, "101", 99_99}]))
    end
  end

  describe "Ledger" do
    test "posting is idempotent by id; a different entry under the same id conflicts" do
      attrs = entry("1", [{:debit, "512", 5_00}, {:credit, "101", 5_00}])
      l = post!(Ledger.new(), attrs)
      assert {:ok, ^l} = Ledger.post(l, attrs)

      assert {:error, {:id_conflict, "1"}} =
               Ledger.post(l, %{attrs | lines: [{:debit, "53", 5_00}, {:credit, "101", 5_00}]})
    end

    test "closed periods are intangible and closing is monotonic" do
      l = Ledger.new() |> Ledger.close(~D[2026-03-31]) |> elem(1)

      assert {:error, {:period_closed, ~D[2026-03-31]}} =
               Ledger.post(l, entry("1", [{:debit, "512", 1}, {:credit, "101", 1}]))

      assert {:error, {:cannot_reopen, ~D[2026-03-31]}} = Ledger.close(l, ~D[2026-01-31])
    end

    test "contrepassation cancels the original entry" do
      l =
        Ledger.new()
        |> post!(entry("1", [{:debit, "512", 7_00}, {:credit, "101", 7_00}]))

      {:ok, l} = Ledger.reverse(l, "1", %{id: "1R", date: ~D[2026-03-06], piece: "AV-1"})
      assert Ledger.balances(l) == %{}

      assert {:error, {:unknown_entry, "x"}} =
               Ledger.reverse(l, "x", %{id: "y", date: @d, piece: "p"})
    end

    test "balance générale: per-account totals and balanced grand totals" do
      l =
        Ledger.new()
        |> post!(entry("1", [{:debit, "512", 1_000_00}, {:credit, "101", 1_000_00}]))
        |> post!(entry("2", [{:debit, "60", 300_00}, {:credit, "512", 300_00}]))

      tb = Ledger.trial_balance(l)
      assert tb.total_debit == tb.total_credit

      assert %{account: "512", debit: 1_000_00, credit: 300_00, balance: 700_00} =
               Enum.find(tb.rows, &(&1.account == "512"))
    end

    test "date window filters balances" do
      l =
        Ledger.new()
        |> post!(entry("1", [{:debit, "512", 1_00}, {:credit, "101", 1_00}]))
        |> post!(
          entry("2", [{:debit, "512", 2_00}, {:credit, "101", 2_00}], %{date: ~D[2026-05-01]})
        )

      assert Ledger.balances(l, to: ~D[2026-04-30]) == %{"101" => -1_00, "512" => 1_00}
      assert Ledger.balances(l, from: ~D[2026-04-01]) == %{"101" => -2_00, "512" => 2_00}
    end
  end

  describe "TVA" do
    test "rates follow the Loi de finances in force on the date" do
      assert Tva.rate(:normal, ~D[2026-01-01]) == {:ok, 19}
      assert Tva.rate(:reduit, ~D[2026-01-01]) == {:ok, 9}
      assert Tva.rate(:normal, ~D[2016-12-31]) == {:ok, 17}
      assert Tva.rate(:normal, ~D[1999-01-01]) == {:error, :no_rate_in_force}
    end

    test "HT → TTC rounds half-up to the centime; TTC → HT preserves ht + tva = ttc" do
      assert Tva.from_ht(10_000_00, 19) == %{ht: 10_000_00, tva: 1_900_00, ttc: 11_900_00}
      assert Tva.from_ht(5, 19) == %{ht: 5, tva: 1, ttc: 6}
      assert %{ht: ht, tva: tva, ttc: 1_00} = Tva.from_ttc(1_00, 19)
      assert ht + tva == 1_00
    end

    test "G50: TVA due = collectée − déductible, or a carried credit" do
      sale = [
        {:debit, "411", 11_900_00},
        {:credit, "700", 10_000_00},
        {:credit, "4457", 1_900_00}
      ]

      buy = [{:debit, "600", 4_000_00}, {:debit, "4456", 760_00}, {:credit, "401", 4_760_00}]

      l =
        Ledger.new()
        |> post!(entry("v1", sale, %{journal: "VT"}))
        |> post!(entry("a1", buy, %{journal: "AC"}))

      assert Tva.g50(l, ~D[2026-03-01], ~D[2026-03-31]) ==
               %{collectee: 1_900_00, deductible: 760_00, due: 1_140_00, credit: 0}

      assert %{due: 0, credit: 760_00} =
               Tva.g50(post!(Ledger.new(), entry("a1", buy)), ~D[2026-03-01], ~D[2026-03-31])
    end
  end

  describe "Statements" do
    setup do
      l =
        Ledger.new()
        |> post!(entry("1", [{:debit, "512", 1_000_000_00}, {:credit, "101", 1_000_000_00}]))
        |> post!(entry("2", [{:debit, "218", 300_000_00}, {:credit, "512", 300_000_00}]))
        |> post!(
          entry("3", [
            {:debit, "411", 595_000_00},
            {:credit, "700", 500_000_00},
            {:credit, "4457", 95_000_00}
          ])
        )
        |> post!(entry("4", [{:debit, "600", 200_000_00}, {:credit, "401", 200_000_00}]))
        |> post!(entry("5", [{:debit, "63", 80_000_00}, {:credit, "512", 80_000_00}]))
        |> post!(entry("6", [{:debit, "681", 30_000_00}, {:credit, "281", 30_000_00}]))
        |> post!(entry("7", [{:debit, "66", 5_000_00}, {:credit, "519", 5_000_00}]))

      %{ledger: l}
    end

    test "TCR par nature: soldes intermédiaires", %{ledger: l} do
      t = Statements.tcr(l)
      assert t.production == 500_000_00
      assert t.consommation == 200_000_00
      assert t.valeur_ajoutee == 300_000_00
      assert t.ebe == 220_000_00
      assert t.resultat_operationnel == 190_000_00
      assert t.resultat_financier == -5_000_00
      assert t.resultat_net == 185_000_00
    end

    test "Bilan: actif = passif, net of amortissements, overdraft as a liability", %{ledger: l} do
      b = Statements.bilan(l)
      assert b.actif.non_courant == 270_000_00
      assert b.passif.capitaux_propres == 1_185_000_00
      assert b.passif.courant == 200_000_00 + 95_000_00 + 5_000_00
      assert b.total_actif == b.total_passif
    end
  end

  test "Money formats DZD the Algerian way" do
    assert Money.format(123_456_789) == "1 234 567,89 DA"
    assert Money.format(-5) == "-0,05 DA"
  end
end
