defmodule BarterCore.Optimizer do
  @moduledoc """
  Exact maximum-cardinality directed cycle packing by assignment with a
  zero-benefit self-loop for nonparticipants. Matching rows (providers) to
  columns (recipients) forms a permutation, hence every non-self edge belongs
  to a closed cycle. Hungarian minimum-cost assignment is polynomial (O(n^3))
  and optimal **only** for the one-indivisible-supply/need-slot model.

  A participant may publish multiple intents; hosts MUST independently
  revalidate cumulative stock/capacity across them before contracting.
  This module never claims optimal values across unlike goods.
  """

  alias BarterCore, as: B

  @default_work_budget 8_000_000

  def optimize(intents, now, opts)
      when is_list(intents) and is_integer(now) and now >= 0 and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- B.validate_feed(intents) do
      active = intents |> Enum.filter(&(&1.valid_until > now)) |> Enum.sort_by(& &1.id)
      n = length(active)
      budget = Keyword.get(opts, :work_budget, @default_work_budget)

      if n * n * n > budget do
        {:error, :work_budget_exceeded}
      else
        {:ok, build_plan(active)}
      end
    end
  end

  def optimize(_, _, _), do: {:error, :invalid_intents}

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) == [:work_budget] and
         is_integer(opts[:work_budget]) and opts[:work_budget] > 0 do
      :ok
    else
      if opts == [], do: :ok, else: {:error, :invalid_options}
    end
  end

  defp build_plan([]) do
    finalize([], [])
  end

  defp build_plan(intents) do
    n = length(intents)
    indexed = List.to_tuple(intents)

    costs =
      Enum.map(0..(n - 1), fn row ->
        from = elem(indexed, row)

        Enum.map(0..(n - 1), fn col ->
          cond do
            row == col -> 1
            B.compatible?(from, elem(indexed, col)) -> 0
            true -> n + 1
          end
        end)
        |> List.to_tuple()
      end)
      |> List.to_tuple()

    assigned = assignment(costs, n)

    cycles =
      1..n
      |> Enum.reduce({MapSet.new(), []}, fn row, {seen, gathered} ->
        cond do
          MapSet.member?(seen, row) ->
            {seen, gathered}

          Map.fetch!(assigned, row) == row ->
            {MapSet.put(seen, row), gathered}

          true ->
            indices = walk(assigned, row, row, [])
            seen = Enum.reduce(indices, seen, fn index, visited -> MapSet.put(visited, index) end)
            first = Enum.min(indices)
            {prefix, suffix} = Enum.split_while(indices, &(&1 != first))

            route =
              (suffix ++ prefix)
              |> Enum.map(&elem(indexed, &1 - 1))
              |> B.cycle()

            {seen, [route | gathered]}
        end
      end)
      |> elem(1)
      |> Enum.sort_by(fn cycle -> hd(cycle.intents).id end)

    finalize(intents, cycles)
  end

  defp finalize(intents, cycles) do
    matched_ids =
      cycles
      |> Enum.flat_map(fn cycle -> Enum.map(cycle.intents, & &1.id) end)
      |> MapSet.new()

    unmatched =
      intents
      |> Enum.reject(&MapSet.member?(matched_ids, &1.id))
      |> Enum.map(& &1.id)

    hash_fields =
      ["bizkit.barter.plan.v1", Integer.to_string(length(intents))] ++
        Enum.flat_map(intents, &B.intent_fields/1) ++
        [Integer.to_string(length(cycles))] ++
        Enum.map(cycles, & &1.terms_hash)

    %{
      schema: "bizkit.barter.plan.v1",
      intents: intents,
      cycles: cycles,
      unmatched: unmatched,
      objective: :max_fulfilled_indivisible_intents,
      matched_intents: MapSet.size(matched_ids),
      optimality: :exact_for_indivisible_slot_model,
      terms_hash: B.digest(hash_fields)
    }
  end

  # The valid assignment is a bijection. Non-self components can therefore
  # only be cycles, never paths or branches.
  defp walk(assigned, start, current, acc) do
    next = Map.fetch!(assigned, current)

    if next == start do
      Enum.reverse([current | acc])
    else
      walk(assigned, start, next, [current | acc])
    end
  end

  # Minimum-cost perfect assignment: valid other-owner edges cost 0,
  # self-loops cost 1, incompatible edges cost n+1. The all-self assignment
  # costs n, so no optimum can contain an incompatible edge. Minimizing
  # self-loops maximizes the count of fulfilled intent slots.
  defp assignment(matrix, n) do
    zeros = Map.new(0..n, &{&1, 0})

    {_u, _v, matching} =
      Enum.reduce(1..n, {zeros, zeros, zeros}, fn row, {u, v, p} ->
        p = Map.put(p, 0, row)
        best = Map.new(1..n, &{&1, (n + 1) * (n + 1) + 1})

        {u, v, p, via, final_col} =
          advance(matrix, n, u, v, p, %{}, best, MapSet.new(), 0)

        {u, v, augment(p, via, final_col)}
      end)

    Enum.reduce(1..n, %{}, fn col, selected ->
      Map.put(selected, Map.fetch!(matching, col), col)
    end)
  end

  defp advance(matrix, n, u, v, p, via, best, used, col0) do
    used = MapSet.put(used, col0)
    row = Map.fetch!(p, col0)

    {best, via, delta, next_col} =
      Enum.reduce(1..n, {best, via, (n + 1) * (n + 1) + 1, 0}, fn col,
                                                                  {best, via, delta, next_col} ->
        if MapSet.member?(used, col) do
          {best, via, delta, next_col}
        else
          price =
            elem(elem(matrix, row - 1), col - 1) -
              Map.fetch!(u, row) - Map.fetch!(v, col)

          {best, via} =
            if price < Map.fetch!(best, col) do
              {Map.put(best, col, price), Map.put(via, col, col0)}
            else
              {best, via}
            end

          if Map.fetch!(best, col) < delta do
            {best, via, Map.fetch!(best, col), col}
          else
            {best, via, delta, next_col}
          end
        end
      end)

    {u, v, best} =
      Enum.reduce(0..n, {u, v, best}, fn col, {u, v, best} ->
        if MapSet.member?(used, col) do
          matched_row = Map.fetch!(p, col)

          {Map.update!(u, matched_row, &(&1 + delta)), Map.update!(v, col, &(&1 - delta)), best}
        else
          updated = if col == 0, do: best, else: Map.update!(best, col, &(&1 - delta))
          {u, v, updated}
        end
      end)

    if Map.fetch!(p, next_col) == 0 do
      {u, v, p, via, next_col}
    else
      advance(matrix, n, u, v, p, via, best, used, next_col)
    end
  end

  defp augment(p, via, col) do
    previous = Map.fetch!(via, col)
    p = Map.put(p, col, Map.fetch!(p, previous))

    if previous == 0, do: p, else: augment(p, via, previous)
  end
end
