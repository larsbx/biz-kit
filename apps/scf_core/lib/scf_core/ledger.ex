defmodule ScfCore.Ledger do
  @moduledoc """
  An immutable, append-only grand livre.

  * Posting is idempotent by entry id; a different entry under a known id is a
    conflict, never an overwrite.
  * Entries dated on or before `closed_through` are refused (intangibility of
    closed periods); closing only moves forward.
  * Corrections are contrepassations (`reverse/3`), never edits or deletions.

  Balances are signed `débit − crédit` per account, in centimes.
  """
  alias ScfCore.{Chart, Entry}

  defstruct entries: %{}, closed_through: nil

  @type t :: %__MODULE__{entries: %{String.t() => Entry.t()}, closed_through: Date.t() | nil}
  @type window :: [from: Date.t(), to: Date.t()]

  def new, do: %__MODULE__{}

  @spec post(t, map) :: {:ok, t} | {:error, term}
  def post(%__MODULE__{} = l, attrs) do
    with {:ok, e} <- Entry.new(attrs) do
      case l.entries[e.id] do
        ^e -> {:ok, l}
        nil -> admit(l, e)
        _ -> {:error, {:id_conflict, e.id}}
      end
    end
  end

  defp admit(%{closed_through: c} = l, e) do
    if c && Date.compare(e.date, c) != :gt,
      do: {:error, {:period_closed, c}},
      else: {:ok, put_in(l.entries[e.id], e)}
  end

  @doc "Closes every period through `date`; a ledger cannot be reopened."
  def close(%{closed_through: c} = l, date) do
    if c && Date.compare(date, c) == :lt,
      do: {:error, {:cannot_reopen, c}},
      else: {:ok, %{l | closed_through: date}}
  end

  @doc "Posts the contrepassation of entry `id`: the same lines with sides swapped."
  def reverse(l, id, %{id: _, date: _, piece: _} = attrs) do
    case l.entries[id] do
      nil ->
        {:error, {:unknown_entry, id}}

      e ->
        lines = for {side, a, m} <- e.lines, do: {swap(side), a, m}

        post(
          l,
          Map.merge(%{journal: e.journal, label: "Contrepassation #{id}", lines: lines}, attrs)
        )
    end
  end

  defp swap(:debit), do: :credit
  defp swap(:credit), do: :debit

  @doc "Entries in the window, ordered by (date, id)."
  @spec entries(t, window) :: [Entry.t()]
  def entries(l, window \\ []) do
    l.entries
    |> Map.values()
    |> Enum.filter(&within?(&1.date, window))
    |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), &1.id})
  end

  @doc "Per-account movements `%{account => {Σ débit, Σ crédit}}` in the window."
  def movements(l, window \\ []) do
    for e <- entries(l, window), {side, a, m} <- e.lines, reduce: %{} do
      acc ->
        Map.update(acc, a, add({0, 0}, side, m), &add(&1, side, m))
    end
  end

  defp add({d, c}, :debit, m), do: {d + m, c}
  defp add({d, c}, :credit, m), do: {d, c + m}

  @doc "Non-zero signed balances `%{account => débit − crédit}` in the window."
  def balances(l, window \\ []) do
    for {a, {d, c}} <- movements(l, window), d != c, into: %{}, do: {a, d - c}
  end

  @doc "Balance générale: one row per moved account, and the grand totals."
  def trial_balance(l, window \\ []) do
    rows =
      for {a, {d, c}} <- Enum.sort(movements(l, window)),
          do: %{account: a, label: Chart.label(a), debit: d, credit: c, balance: d - c}

    %{
      rows: rows,
      total_debit: Enum.sum_by(rows, & &1.debit),
      total_credit: Enum.sum_by(rows, & &1.credit)
    }
  end

  defp within?(d, window) do
    (is_nil(window[:from]) or Date.compare(d, window[:from]) != :lt) and
      (is_nil(window[:to]) or Date.compare(d, window[:to]) != :gt)
  end
end
