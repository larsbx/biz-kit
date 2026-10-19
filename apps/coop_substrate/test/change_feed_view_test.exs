defmodule CoopSubstrate.ChangeFeedViewTest do
  @moduledoc """
  `CoopSubstrate.Feed.View` over the generated histories of
  `CoopSubstrate.TaskHistories`: a client that applies the feed's frames, cut
  at any batch boundaries, holds exactly the view a fresh read gives. Each
  property holds for every view a feed serves: a project's, without a reader
  and as Alice reads it (with her devices), and the chapter's
  (docs/architecture/2026-10-19-live-view.md).
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

  @views [{@scope, nil}, {@scope, "alice"}, {{"chapter-genesis"}, nil}]

  defp view(gate, {scope, principal}),
    do: View.select(gate, scope, principal)

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

      for {scope, _} = v <- @views do
        empty = View.empty(scope)
        start = View.apply(empty, View.diff(empty, view(gate0, v)))

        {client, _} =
          steps
          |> batch_ends(cuts)
          |> Enum.reduce({start, view(gate0, v)}, fn next, {client, server} ->
            {View.apply(client, View.diff(server, view(next, v))), view(next, v)}
          end)

        assert client == view(gate, v)
      end
    end
  end

  property "a frame changes only what changed, each entity at most once", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, _gate} = run(ops, w, gate0)

      for {_env, before, next} <- steps, v <- @views do
        old = view(before, v)
        new = view(next, v)
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

      for {scope, _} = v <- @views do
        json = Jason.encode!(View.diff(View.empty(scope), view(gate, v)))

        o = gate.orchestration

        for a <- Map.values(o.delegations) ++ Map.values(o.grants),
            do: refute(json =~ Base.encode16(a.pubkey, case: :lower))
      end
    end
  end

  property "another project's view never sees this project's events", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 100) do
      {_steps, gate} = run(ops, w, gate0)

      for scope <- [{"chapter-genesis", "tenant-1", "project-2"}, {"chapter-other", "t", "p"}],
          do: assert(view(gate, {scope, "alice"}) == View.empty(scope))

      assert view(gate, {{"chapter-other"}, nil}) == View.empty({"chapter-other"})
    end
  end

  test "generated histories put every kind in the views", %{
    world: w,
    gate0: gate0
  } do
    gen = StreamData.resize(history_gen(), 30)

    kinds =
      1..200
      |> Enum.flat_map(fn i ->
        ops = gen |> StreamData.seeded(20_261_018 + i) |> Enum.at(0)
        {_steps, gate} = run(ops, w, gate0)

        for v <- @views,
            {kind, entities} <- view(gate, v),
            entities != %{},
            do: kind
      end)
      |> MapSet.new()

    assert kinds ==
             MapSet.new(
               ~w(tasks suggestions delegations receipts devices projects administrators)a
             )
  end
end
