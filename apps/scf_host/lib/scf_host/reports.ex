defmodule ScfHost.Reports do
  @moduledoc """
  Views of a signed book (`CoopSubstrate.Scf.book/2`): the journal with log
  positions and reversal links, and the statements of a window, all computed
  by `ScfCore`. Pure.
  """
  alias ScfCore.{Ledger, Statements, Tva}

  @doc "Journal rows in (date, position) order."
  def journal(book) do
    for e <- Ledger.entries(book.ledger) do
      seq = sequence(e.id)

      %{
        sequence: seq,
        date: e.date,
        journal: e.journal,
        piece: e.piece,
        label: e.label,
        lines: e.lines,
        debit: ScfCore.Entry.total(e, :debit),
        credit: ScfCore.Entry.total(e, :credit),
        reverses: get_in(book.postings, [seq, :reverses, :sequence]),
        reversible: Map.has_key?(book.postings, seq) and not MapSet.member?(book.reversed, seq)
      }
    end
  end

  @doc "Balance générale, TCR, bilan (at the window's end) and G50 TVA position."
  def statements(book, params) do
    window = window(params, book.open_year)

    %{
      window: window,
      trial_balance: Ledger.trial_balance(book.ledger, window),
      tcr: Statements.tcr(book.ledger, window),
      bilan: Statements.bilan(book.ledger, at: window[:to]),
      g50: Tva.g50(book.ledger, window[:from], window[:to])
    }
  end

  @doc "`mois=YYYY-MM`, or `du`/`au` (`from`/`to`) ISO dates; else the exercice."
  def window(%{"mois" => month}, year) when is_binary(month) do
    with {:ok, first} <- Date.from_iso8601(month <> "-01"),
         do: [from: first, to: Date.end_of_month(first)],
         else: (_ -> ScfCore.exercice(year))
  end

  def window(params, year) do
    [default_from, default_to] = Keyword.values(ScfCore.exercice(year))

    case {date(params["du"] || params["from"], default_from),
          date(params["au"] || params["to"], default_to)} do
      {{:ok, from}, {:ok, to}} ->
        if Date.compare(from, to) != :gt, do: [from: from, to: to], else: ScfCore.exercice(year)

      _ ->
        ScfCore.exercice(year)
    end
  end

  defp date(nil, default), do: {:ok, default}

  defp date(text, default) when is_binary(text),
    do: if(text == "", do: {:ok, default}, else: Date.from_iso8601(text))

  defp date(_, _), do: :error

  @doc "Plain JSON data: ISO dates, integer centimes, string sides and keys."
  def to_json(%Date{} = d), do: Date.to_iso8601(d)
  def to_json(%MapSet{} = s), do: s |> MapSet.to_list() |> to_json()
  def to_json(%{__struct__: _} = s), do: s |> Map.from_struct() |> to_json()

  def to_json({side, account, amount}) when side in [:debit, :credit],
    do: %{"side" => Atom.to_string(side), "account" => account, "amount_minor" => amount}

  def to_json(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), to_json(v)} end)
  def to_json([{k, _} | _] = kw) when is_atom(k), do: kw |> Map.new() |> to_json()
  def to_json(l) when is_list(l), do: Enum.map(l, &to_json/1)
  def to_json(v), do: v

  defp sequence("signed-scf-v1:" <> n), do: String.to_integer(n)
end
