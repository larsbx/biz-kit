defmodule CoopSubstrate.Finance do
  @moduledoc """
  Finance read-side (Phase 1C step 7): netting over the obligation rail
  (corpus 05 §1.2) — "netting is a computation over this rail; settlement is
  evidence about it". Period-end set-off of like-denominated mutual open
  obligations between a pair of members (05 P5: never across denominations;
  05 P10: a pure function of the log).

  The report became executable in 9A (docs/phase9a_plan.md):
  `NettingExecuted` is the dual-signed batch discharge, and the append gate
  recomputes `compute/3` on it — a round that disagrees with this module is
  unrepresentable. The obligations come from the same fold the append gate
  holds (`Projections.Membership`) — one fold, two consumers; a separate
  `Projections.Obligations` turned out to be unnecessary (1C plan step 7
  note).

  Ring visibility (9A): `ring_stats/2` reports circular structures among
  open obligations as counts and gross value ONLY — a member roster never
  crosses the boundary (05 §2: chapter-level exposure is a
  privacy-preserving aggregate; acting on a nonzero count is an
  R/governance matter).
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

  @doc """
  Circular-structure aggregate per denomination over OPEN obligations:
  `%{denomination => %{rings, gross_minor}}` where `rings` counts strongly
  connected debtor→creditor components (size ≥ 2) and `gross_minor` sums
  the obligations inside them. No member ids in the output. Supports
  `as_of:`.
  """
  @spec ring_stats(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ring_stats(chapter_id, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts) do
      stats =
        for {{^chapter_id, _id}, %{open: true} = ob} <- state.obligations do
          ob
        end
        |> Enum.group_by(& &1.denomination)
        |> Map.new(fn {denomination, obligations} ->
          {denomination, denomination_rings(obligations)}
        end)

      {:ok, stats}
    end
  end

  defp denomination_rings(obligations) do
    edges = Enum.map(obligations, &{&1.debtor_id, &1.creditor_id, &1.amount_minor})
    nodes = edges |> Enum.flat_map(fn {d, c, _} -> [d, c] end) |> Enum.uniq() |> Enum.sort()
    adjacency = Enum.group_by(edges, fn {d, _, _} -> d end, fn {_, c, _} -> c end)
    reverse = Enum.group_by(edges, fn {_, c, _} -> c end, fn {d, _, _} -> d end)

    # Kosaraju: post-order over the graph, then collect components on the
    # reverse graph in decreasing finish order.
    {_, order} =
      Enum.reduce(nodes, {MapSet.new(), []}, fn node, acc -> post_order(node, adjacency, acc) end)

    {_, components} =
      Enum.reduce(order, {MapSet.new(), []}, fn node, {visited, components} ->
        if MapSet.member?(visited, node) do
          {visited, components}
        else
          {visited, members} = collect(node, reverse, visited, [])
          {visited, [members | components]}
        end
      end)

    ring_members =
      components
      |> Enum.filter(&(length(&1) > 1))
      |> Enum.with_index()
      |> Enum.flat_map(fn {members, index} -> Enum.map(members, &{&1, index}) end)
      |> Map.new()

    gross =
      edges
      |> Enum.filter(fn {d, c, _} ->
        ring_members[d] != nil and ring_members[d] == ring_members[c]
      end)
      |> Enum.map(fn {_, _, amount} -> amount end)
      |> Enum.sum()

    %{
      rings: ring_members |> Map.values() |> Enum.uniq() |> length(),
      gross_minor: gross
    }
  end

  defp post_order(node, adjacency, {visited, order}) do
    if MapSet.member?(visited, node) do
      {visited, order}
    else
      {visited, order} =
        Enum.reduce(
          Map.get(adjacency, node, []),
          {MapSet.put(visited, node), order},
          fn next, acc -> post_order(next, adjacency, acc) end
        )

      {visited, [node | order]}
    end
  end

  defp collect(node, reverse, visited, members) do
    if MapSet.member?(visited, node) do
      {visited, members}
    else
      Enum.reduce(
        Map.get(reverse, node, []),
        {MapSet.put(visited, node), [node | members]},
        fn next, {v, m} -> collect(next, reverse, v, m) end
      )
    end
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
