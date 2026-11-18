defmodule ScfCore.SourceCorrespondenceTest do
  use ExUnit.Case
  alias ScfCore.{Chart, Entry, Ledger, Statements}

  @day ~D[2024-02-29]
  @next ~D[2024-03-01]
  @lines [{:debit, "512", 100}, {:credit, "101", 100}]

  defp opening do
    %{id: "1", date: @day, journal: "BQ", piece: "opening", lines: @lines}
  end

  defp date(day), do: Date.to_gregorian_days(day)
  defp option(nil, _), do: "none"
  defp option(value, encode), do: "(some #{encode.(value)})"

  defp list(values, encode), do: "[" <> Enum.map_join(values, ", ", encode) <> "]"

  defp lines(lines) do
    list(lines, fn {side, code, amount} ->
      "⟨.#{side}, #{account(code)}, #{amount}⟩"
    end)
  end

  @prefixes [
              {"capital", ~w(10 11 12)},
              {"debt", ~w(13 15 16 17 18)},
              {"asset", ~w(20 21 22 23 26 27 28 29)},
              {"stock", ~w(30 31 32 33 34 35 36 37 38 39)},
              {"tiers", ~w(40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 58 59)}
            ] ++
              for(prefix <- 60..69, do: {"c#{prefix}", [Integer.to_string(prefix)]}) ++
              for(
                prefix <- [70 | Enum.to_list(72..78)],
                do: {"p#{prefix}", [Integer.to_string(prefix)]}
              )

  @buckets Map.new(for {bucket, prefixes} <- @prefixes, prefix <- prefixes, do: {prefix, bucket})

  defp account(code) do
    bucket = Map.fetch!(@buckets, binary_part(code, 0, 2))
    "⟨.#{bucket}, #{code}⟩"
  end

  defp metadata(entry) do
    {entry.journal, entry.piece, entry.label}
    |> :erlang.term_to_binary([:deterministic])
    |> Base.encode16()
    |> inspect()
  end

  defp entry(entry) do
    "(⟨#{entry.id}, #{date(entry.date)}, #{metadata(entry)}, #{lines(entry.lines)}⟩ : Entry)"
  end

  # Serialize the actual entries map, in fixture insertion order. In these traces
  # fresh IDs increase, so descending ID reconstructs the Lean cons order.
  defp ledger(ledger) do
    entries =
      ledger.entries
      |> Enum.map(fn {id, e} ->
        assert id === e.id
        e
      end)
      |> Enum.sort_by(&String.to_integer(&1.id), :desc)

    "(⟨#{list(entries, &entry/1)}, #{option(ledger.closed_through, &date/1)}⟩ : Ledger)"
  end

  defp claim(proposition) do
    if path = System.get_env("SCF_LEAN_OBSERVATIONS") do
      File.write!(path, "example : #{proposition} := by decide\n", [:append])
    end
  end

  defp post(state, attrs) do
    assert {:ok, accepted} = Entry.new(attrs)
    claim("Admitted #{entry(accepted)}")
    assert {:ok, result} = Ledger.post(state, attrs)
    claim("post #{ledger(state)} #{entry(accepted)} = some #{ledger(result)}")
    result
  end

  defp close(state, day) do
    assert {:ok, result} = Ledger.close(state, day)
    claim("close #{ledger(state)} #{date(day)} = some #{ledger(result)}")
    result
  end

  defp reversal_attrs(state, attrs) do
    original = Map.fetch!(state.entries, "1")

    effective =
      Map.merge(
        %{journal: original.journal, label: "Contrepassation 1"},
        attrs
      )

    "(⟨#{attrs.id}, #{date(attrs.date)}, #{metadata(effective)}, " <>
      "#{option(Map.get(attrs, :lines), &lines/1)}⟩ : ReverseAttrs)"
  end

  defp reverse(state, attrs) do
    assert {:ok, result} = Ledger.reverse(state, "1", attrs)
    claim("reverse #{ledger(state)} 1 #{reversal_attrs(state, attrs)} = some #{ledger(result)}")
    result
  end

  test "validation, exact retry and closure agree on the recorded trace" do
    attrs = opening()
    state = post(Ledger.new(), attrs)
    closed = close(state, @day)

    assert post(closed, Map.merge(attrs, %{label: "", ignored: true})) === closed
    assert close(closed, @day) === closed
    assert close(closed, @next).closed_through == @next

    for changed <- [%{label: 1}, %{lines: Enum.reverse(@lines)}] do
      candidate = Map.merge(attrs, changed)
      assert {:ok, accepted} = Entry.new(candidate)
      assert Ledger.post(closed, candidate) == {:error, {:id_conflict, "1"}}
      claim("post #{ledger(closed)} #{entry(accepted)} = none")
    end

    fresh = %{attrs | id: "2"}
    assert {:ok, accepted} = Entry.new(fresh)
    assert Ledger.post(closed, fresh) == {:error, {:period_closed, @day}}
    claim("post #{ledger(closed)} #{entry(accepted)} = none")

    prior = ~D[2024-02-28]
    assert Ledger.close(closed, prior) == {:error, {:cannot_reopen, @day}}
    claim("close #{ledger(closed)} #{date(prior)} = none")
  end

  test "validation refusals precede an ID conflict or period closure" do
    attrs = opening()
    closed = Ledger.new() |> post(attrs) |> close(@day)

    unbalanced = %{attrs | lines: [{:debit, "512", 100}, {:credit, "101", 99}]}

    cases = [
      {unbalanced, [{:unbalanced, 100, 99}]},
      {%{attrs | lines: [{:debit, "512", 0}, {:credit, "101", 0}]},
       [{:non_positive_amount, "512"}, {:non_positive_amount, "101"}]},
      {%{attrs | lines: [{:debit, "14", 100}, {:credit, "101", 100}]},
       [{:invalid_account, "14"}]},
      {%{attrs | id: " ", piece: "", date: :bad, journal: "bq", lines: []},
       [:missing_id, :missing_piece, :invalid_journal, :invalid_date, :fewer_than_two_lines]}
    ]

    for {candidate, errors} <- cases do
      assert Entry.new(candidate) == {:error, errors}
      assert Ledger.post(closed, candidate) == {:error, errors}
    end

    encoded = struct!(Entry, unbalanced)
    claim("¬ Admitted #{entry(encoded)}")
    claim("post #{ledger(closed)} #{entry(encoded)} = none")
  end

  test "reversal preserves caller overrides and permits distinct reversal IDs" do
    attrs = opening()
    closed = Ledger.new() |> post(attrs) |> close(@day)
    correction = %{id: "2", date: @next, piece: "correction"}

    assert Ledger.reverse(closed, "missing", correction) ==
             {:error, {:unknown_entry, "missing"}}

    claim("reverse #{ledger(closed)} 99 #{reversal_attrs(closed, correction)} = none")

    too_early = %{correction | date: @day}
    assert Ledger.reverse(closed, "1", too_early) == {:error, {:period_closed, @day}}
    claim("reverse #{ledger(closed)} 1 #{reversal_attrs(closed, too_early)} = none")

    assert Ledger.reverse(closed, "1", Map.put(correction, :lines, nil)) ==
             {:error, [:fewer_than_two_lines, :invalid_lines]}

    once = reverse(closed, correction)
    assert reverse(once, correction) === once
    assert Ledger.balances(once) == %{}
    assert Ledger.balances(once, to: @day) == %{"512" => 100, "101" => -100}

    twice = reverse(once, %{correction | id: "3"})
    assert Ledger.balances(twice) == %{"512" => -100, "101" => 100}

    overridden = reverse(closed, Map.merge(correction, %{lines: @lines, label: :override}))
    assert overridden.entries["2"].label == :override
    assert Ledger.balances(overridden) == %{"512" => 200, "101" => -200}
  end

  test "canonical account prefixes match the chart for all two-digit candidates" do
    for prefix <- 10..99 do
      code = Integer.to_string(prefix)
      admitted = Map.has_key?(@buckets, code)

      for suffix <- ["", "0", "012345", "0123456"] do
        assert Chart.account?(code <> suffix) == (admitted and byte_size(suffix) <= 6)
      end
    end

    for {code, label} <- Chart.accounts() do
      assert Map.has_key?(@buckets, binary_part(code, 0, 2))
      assert Chart.label(code) == label
      if byte_size(code) < 8, do: assert(Chart.account?(code <> "0"))
    end
  end

  test "chart accepts a final newline and preserves it in account identity" do
    code = "512\n"
    assert Chart.account?(code)
    assert Chart.label(code) == Chart.label("512")

    attrs = %{opening() | lines: [{:debit, code, 100}, {:credit, "512", 100}]}
    assert {:ok, state} = Ledger.post(Ledger.new(), attrs)
    assert Ledger.balances(state) == %{code => 100, "512" => -100}
    assert Statements.bilan(state).total_actif == 100
    assert Statements.bilan(state).total_passif == 100
  end

  test "statement inputs match movements selected by inclusive date bounds" do
    before = Date.add(@day, -1)
    after_window = Date.add(@next, 1)

    state =
      Ledger.new()
      |> post(%{
        opening()
        | id: "1",
          date: before,
          lines: [{:debit, "512", 9}, {:credit, "101", 9}]
      })
      |> post(%{opening() | id: "2", lines: [{:debit, "5120", 100}, {:credit, "700", 100}]})
      |> post(%{
        opening()
        | id: "3",
          date: @next,
          lines: [{:debit, "600", 30}, {:credit, "5121", 30}]
      })
      |> post(%{
        opening()
        | id: "4",
          date: @next,
          lines: [{:debit, "411", 5}, {:credit, "411", 5}]
      })
      |> post(%{opening() | id: "5", date: after_window})

    window = [from: @day, to: @next]

    assert Enum.map(Ledger.entries(state, window), & &1.id) == ["2", "3", "4"]
    assert Enum.map(Ledger.entries(state, from: @next), & &1.id) == ["3", "4", "5"]

    assert Ledger.balances(state, window) == %{
             "5120" => 100,
             "5121" => -30,
             "600" => 30,
             "700" => -100
           }

    observe_statements(state, window, false)
    observe_statements(state, [to: @next], true)
  end

  defp observe_statements(state, window, bilan?) do
    entries = Ledger.entries(state, window)
    rows = Enum.sort(Ledger.movements(state, window))
    balances = Enum.sort(Ledger.balances(state, window))

    encoded_rows =
      list(rows, fn {code, {debit, credit}} -> "⟨#{account(code)}, #{debit}, #{credit}⟩" end)

    encoded_balances =
      list(balances, fn {code, amount} -> "⟨#{account(code)}, #{amount}⟩" end)

    actual = "(#{encoded_balances} : List Balance)"
    claim("Source.signedBalances #{encoded_rows} = #{actual}")

    claim(
      "ledgerDebits #{list(entries, &entry/1)} = #{Enum.sum_by(rows, fn {_, {d, _}} -> d end)}"
    )

    claim(
      "ledgerCredits #{list(entries, &entry/1)} = #{Enum.sum_by(rows, fn {_, {_, c}} -> c end)}"
    )

    claim("trialNet #{actual} = 0")
    claim("resultNet #{actual} = #{Statements.tcr(state, window).resultat_net}")

    if bilan? do
      statement = Statements.bilan(state, at: window[:to])
      assert statement.total_actif == 109
      assert statement.total_passif == 109
      claim("totalAssets #{actual} = #{statement.total_actif}")
      claim("totalLiabilities #{actual} = #{statement.total_passif}")
    end
  end
end
