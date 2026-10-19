defmodule CoopSubstrate.ChangeFeedViewTest do
  @moduledoc """
  `CoopSubstrate.Feed.View` over the generated histories of
  `CoopSubstrate.TaskHistories`: a client that applies the feed's frames, cut
  at any batch boundaries, holds exactly the project view a fresh read gives.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CoopSubstrate.TaskHistories

  alias CoopSubstrate.Feed.View

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup_all do
    {world, gate0} = world()
    %{world: world, gate0: gate0}
  end

  defp view(gate, scope \\ @scope), do: View.select(gate.orchestration, scope)

  # The gates a client passes through when the steps arrive in batches: `cuts`
  # says, per step, whether a batch ends after it. The last step always ends one.
  defp batch_ends(steps, cuts) do
    steps
    |> Enum.with_index()
    |> Enum.filter(fn {_, i} -> i == length(steps) - 1 or Enum.at(cuts, i, false) end)
    |> Enum.map(fn {{_env, _before, next}, _} -> next end)
  end

  property "applying the frames reproduces the view, however events are batched", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), cuts <- list_of(boolean()), max_runs: 150) do
      {steps, gate} = run(ops, w, gate0)
      start = View.apply(View.empty(), View.diff(View.empty(), view(gate0)))

      {client, _} =
        steps
        |> batch_ends(cuts)
        |> Enum.reduce({start, view(gate0)}, fn next, {client, server} ->
          {View.apply(client, View.diff(server, view(next))), view(next)}
        end)

      assert client == view(gate)
    end
  end

  property "a frame changes only what changed, each entity at most once", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, _gate} = run(ops, w, gate0)

      for {_env, before, next} <- steps do
        old = view(before)
        new = view(next)
        changes = View.diff(old, new)

        assert View.diff(new, new) == []
        assert length(Enum.uniq_by(changes, &{&1.kind, &1.id})) == length(changes)

        for %{kind: kind, id: id, value: value} <- changes do
          assert get_in(old, [kind, id]) != value
          assert get_in(new, [kind, id]) == value
        end
      end
    end
  end

  property "frames encode as JSON and carry no signing keys", %{world: w, gate0: gate0} do
    check all(ops <- history_gen(), max_runs: 100) do
      {_steps, gate} = run(ops, w, gate0)
      changes = View.diff(View.empty(), view(gate))
      json = Jason.encode!(changes)

      for {_, d} <- gate.orchestration.delegations,
          do: refute(json =~ Base.encode16(d.pubkey, case: :lower))
    end
  end

  property "another project's view never sees this project's events", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 100) do
      {_steps, gate} = run(ops, w, gate0)
      assert view(gate, {"chapter-genesis", "tenant-1", "project-2"}) == View.empty()
      assert view(gate, {"chapter-other", "tenant-1", "project-1"}) == View.empty()
    end
  end

  test "generated histories put tasks, suggestions, delegations and receipts in the view", %{
    world: w,
    gate0: gate0
  } do
    gen = StreamData.resize(history_gen(), 30)

    kinds =
      1..200
      |> Enum.flat_map(fn i ->
        ops = gen |> StreamData.seeded(20_261_018 + i) |> Enum.at(0)
        {_steps, gate} = run(ops, w, gate0)
        gate |> view() |> Enum.filter(fn {_kind, entities} -> entities != %{} end)
      end)
      |> MapSet.new(&elem(&1, 0))

    assert kinds == MapSet.new([:tasks, :suggestions, :delegations, :receipts])
  end
end
