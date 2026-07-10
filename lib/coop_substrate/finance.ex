defmodule CoopSubstrate.Finance do
  @moduledoc """
  Finance read-side (Phase 1C step 7): netting over the obligation rail
  (corpus 05 §1.2) — "netting is a computation over this rail; settlement is
  evidence about it". Period-end set-off of like-denominated mutual open
  obligations between a pair of members (05 P5: never across denominations;
  05 P10: a pure function of the log).

  This is a *report*, not an event: executing a netting round (batch
  discharge) is deferred workflow (docs/phase1c_plan.md, deferred list).
  The obligations come from the same fold the append gate holds
  (`Projections.Membership`) — one fold, two consumers; a separate
  `Projections.Obligations` turned out to be unnecessary (plan step 7 note).
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @doc """
  Pairwise netting for `{a, b}` in a chapter: per denomination, the open
  gross positions each way, the set-off (min of the two), and the residual
  net as `{debtor, creditor, amount_minor}` (nil when balanced).
  Supports `as_of:`.
  """
  @spec netting(String.t(), {String.t(), String.t()}, keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def netting(chapter_id, {a, b}, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts) do
      {:ok, compute(state.obligations, chapter_id, {a, b})}
    end
  end

  @doc """
  The pure set-off core over an obligations map (fold-shaped:
  `%{{chapter_id, obligation_id} => %{debtor_id, creditor_id, amount_minor,
  denomination, open}}`). Exposed for property tests.
  """
  def compute(obligations, chapter_id, {a, b}) do
    obligations
    |> Enum.filter(fn {{ch, _id}, ob} ->
      ch == chapter_id and ob.open and between?(ob, a, b)
    end)
    |> Enum.group_by(fn {_key, ob} -> ob.denomination end)
    |> Enum.map(fn {denomination, entries} ->
      a_to_b = gross(entries, a)
      b_to_a = gross(entries, b)
      setoff = min(a_to_b, b_to_a)

      net =
        cond do
          a_to_b > b_to_a -> {a, b, a_to_b - b_to_a}
          b_to_a > a_to_b -> {b, a, b_to_a - a_to_b}
          true -> nil
        end

      %{denomination: denomination, a_to_b: a_to_b, b_to_a: b_to_a, setoff: setoff, net: net}
    end)
    |> Enum.sort_by(& &1.denomination)
  end

  defp between?(%{debtor_id: d, creditor_id: c}, a, b) do
    {d, c} == {a, b} or {d, c} == {b, a}
  end

  defp gross(entries, debtor) do
    entries
    |> Enum.filter(fn {_key, ob} -> ob.debtor_id == debtor end)
    |> Enum.map(fn {_key, ob} -> ob.amount_minor end)
    |> Enum.sum()
  end
end
