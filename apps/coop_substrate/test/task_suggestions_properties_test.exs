defmodule CoopSubstrate.TaskSuggestionsPropertiesTest do
  @moduledoc """
  The invariants of spec/task_suggestions.qnt as properties over the generated
  histories of `CoopSubstrate.TaskHistories`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CoopSubstrate.TaskHistories

  alias CoopSubstrate.Projections.Tasks, as: Projection

  @suggester_types ~w(TaskChangeSuggestedV1 TaskSuggestionWithdrawnV1 TaskSuggestionArtifactRecordedV1)
  @task_commands ~w(TaskCreatedV1 TaskTimingRevisedV1 TaskProposedV1)

  setup_all do
    {world, gate0} = world()
    %{world: world, gate0: gate0}
  end

  defp fold(envs, init), do: Enum.reduce(envs, init, &Projection.handle_event/2)

  defp resolving_events(steps, id) do
    Enum.filter(steps, fn {env, before, _} ->
      env.payload["suggestion_event_id"] == id or
        (env.type == "TaskCreatedV1" and superseded_by?(before, env, id))
    end)
  end

  defp superseded_by?(before, env, id) do
    case before.orchestration.suggestions[id] do
      %{status: :pending, kind: "create", task_id: t} -> t == env.payload["task_id"]
      _ -> false
    end
  end

  # -- properties --------------------------------------------------------------

  property "no agent effect: suggester events never change task state", %{world: w, gate0: gate0} do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, _gate} = run(ops, w, gate0)
      envs = Enum.map(steps, &elem(&1, 0))
      base = gate0.orchestration

      assert fold(envs, base).tasks ==
               fold(Enum.reject(envs, &(&1.type in @suggester_types)), base).tasks

      for {env, before, next} <- steps, env.type in @suggester_types do
        assert next.orchestration.tasks == before.orchestration.tasks
        assert next.orchestration.custody_receipts == before.orchestration.custody_receipts
      end
    end
  end

  property "the live gate state equals a replay of accepted events", %{world: w, gate0: gate0} do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, gate} = run(ops, w, gate0)
      assert gate.orchestration == fold(Enum.map(steps, &elem(&1, 0)), gate0.orchestration)
    end
  end

  property "facet independence", %{world: w, gate0: gate0} do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, _gate} = run(ops, w, gate0)

      for {env, before, next} <- steps,
          key <- [task_key(env)],
          Map.has_key?(before.orchestration.tasks, key) do
        b = before.orchestration.tasks[key]
        a = next.orchestration.tasks[key]

        case env.type do
          "TaskTimingRevisedV1" -> assert {a.version, a.state} == {b.version, b.state}
          "TaskProposedV1" -> assert {a.timing_version, a.timing} == {b.timing_version, b.timing}
          _ -> :ok
        end
      end
    end
  end

  property "each suggestion is resolved by exactly one event once closed, and stays closed", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, gate} = run(ops, w, gate0)

      for {id, s} <- gate.orchestration.suggestions do
        resolvers = resolving_events(steps, id)

        if s.status == :pending do
          assert resolvers == [] and s.resolved_by_event_id == nil
        else
          assert [{resolver, _, _}] = resolvers
          assert s.resolved_by_event_id == resolver.event_id
        end
      end

      for {_env, before, next} <- steps,
          {id, s} <- before.orchestration.suggestions,
          s.status != :pending do
        assert next.orchestration.suggestions[id] == s
      end
    end
  end

  property "accepted iff the applied body is the Δ, amended iff not", %{world: w, gate0: gate0} do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, gate} = run(ops, w, gate0)
      by_id = Map.new(steps, fn {env, _, _} -> {env.event_id, env} end)

      for {_id, %{status: status} = s} <- gate.orchestration.suggestions,
          status in [:accepted, :amended] do
        # The body is every field the command would take from the Δ.
        fields = if s.kind == "create", do: ~w(title timing description), else: ~w(timing)
        applied = Map.take(by_id[s.resolved_by_event_id].payload, fields)
        assert applied == Map.take(s.change, fields) == (status == :accepted)
      end
    end
  end

  property "agent receipts are isolated from custody and cited only by their owner", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 150) do
      {_steps, gate} = run(ops, w, gate0)
      o = gate.orchestration

      assert MapSet.disjoint?(
               MapSet.new(Map.keys(o.suggestion_artifacts)),
               MapSet.new(Map.keys(o.custody_receipts))
             )

      for {_id, s} <- o.suggestions do
        for r <- [s.rationale_receipt_id, s.status == :withdrawn && s.reason_receipt_id],
            is_binary(r) do
          assert o.suggestion_artifacts[r].principal_id == s.principal_id
        end

        if s.status == :declined and is_binary(s.reason_receipt_id) do
          assert Map.has_key?(o.custody_receipts, s.reason_receipt_id)
        end

        # Reasons survive closure.
        if is_binary(s.rationale_receipt_id),
          do: assert(Map.has_key?(o.suggestion_artifacts, s.rationale_receipt_id))
      end
    end
  end

  # Delegation properties, recomputed here from the gate state before each
  # admitted command rather than through the implementation's checks.

  defp in_window?(%{"kind" => "timed", "start_ms" => from, "end_ms" => to}, d),
    do: from >= d.window["not_before_ms"] and to <= d.window["not_after_ms"]

  defp in_window?(_schedule, _d), do: false

  property "every task change traces to a live grant or delegation and stays in its limits", %{
    world: w,
    gate0: gate0
  } do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, _gate} = run(ops, w, gate0)

      for {env, before, _next} <- steps, env.type in @task_commands do
        o = before.orchestration
        auth = env.payload["authorization_event_id"]

        case o.grants[auth] do
          %{active: true} ->
            :ok

          nil ->
            d = o.delegations[auth]
            # Lifecycle stays human; the delegation is live.
            assert env.type != "TaskProposedV1"
            assert d.active and o.grants[d.operator_grant_id].active and d.used < d.budget
            assert is_nil(d.task_ids) or env.payload["task_id"] in d.task_ids
            timing = env.payload["timing"]
            new_slot = timing["schedule"]

            assert is_nil(new_slot) or
                     (in_window?(new_slot, d) and
                        new_slot["end_ms"] - new_slot["start_ms"] <= d.max_block_ms)

            case env.type do
              "TaskCreatedV1" ->
                assert "create" in d.kinds and timing["due_ms"] == nil

              "TaskTimingRevisedV1" ->
                task = o.tasks[Projection.task_key(env)]
                assert "timing" in d.kinds and task.state in (d.states || ["inbox", "proposed"])
                assert timing["due_ms"] == task.timing["due_ms"]
                assert in_window?(new_slot, d)
                assert is_nil(task.timing["schedule"]) or in_window?(task.timing["schedule"], d)
            end
        end
      end
    end
  end

  property "no delegation admits more changes than its budget", %{world: w, gate0: gate0} do
    check all(ops <- history_gen(), max_runs: 150) do
      {steps, gate} = run(ops, w, gate0)

      for {id, d} <- gate.orchestration.delegations do
        uses =
          Enum.count(steps, fn {env, _, _} ->
            env.payload["authorization_event_id"] == id and env.type in @task_commands
          end)

        assert uses == d.used and uses <= d.budget
      end
    end
  end

  # Reachability is a coverage claim, not a sample. StreamData enumerates from a
  # clock-derived seed, so the same test could pass locally and fail in CI. Here
  # history i comes from seed @coverage_seed + i at full size: distinct,
  # reproducible histories, consumed until every target outcome has appeared.
  @coverage_seed 20_261_018
  @coverage_budget 3_000

  defp coverage_histories do
    gen = StreamData.resize(history_gen(), 30)

    Stream.map(
      1..@coverage_budget,
      &(gen |> StreamData.seeded(@coverage_seed + &1) |> Enum.at(0))
    )
  end

  defp reached(targets, outcomes, w, gate0) do
    Enum.reduce_while(coverage_histories(), MapSet.new(), fn ops, seen ->
      seen = MapSet.union(seen, MapSet.new(outcomes.(run(ops, w, gate0))))
      if MapSet.subset?(targets, seen), do: {:halt, seen}, else: {:cont, seen}
    end)
  end

  test "generated histories reach delegated changes and exhausted budgets", %{
    world: w,
    gate0: gate0
  } do
    targets = MapSet.new(["TaskCreatedV1", "TaskTimingRevisedV1", :exhausted])

    outcomes = fn {steps, gate} ->
      delegations = gate.orchestration.delegations

      for(
        {env, _, _} <- steps,
        Map.has_key?(delegations, env.payload["authorization_event_id"]),
        do: env.type
      ) ++
        for({_, d} <- delegations, d.used == d.budget, do: :exhausted)
    end

    assert MapSet.subset?(targets, reached(targets, outcomes, w, gate0))
  end

  test "generated histories reach every suggestion status", %{world: w, gate0: gate0} do
    targets = MapSet.new([:pending, :accepted, :amended, :declined, :withdrawn, :superseded])

    statuses = fn {_steps, gate} ->
      Enum.map(gate.orchestration.suggestions, fn {_, s} -> s.status end)
    end

    assert reached(targets, statuses, w, gate0) == targets
  end

  test "generated histories offboard the operator, the agent and the delegate", %{
    world: w,
    gate0: gate0
  } do
    targets = MapSet.new(~w(alice bot deleg-bot))

    offboarded = fn {steps, _gate} ->
      for {%{type: "TaskPrincipalOffboardedV1"} = env, _, _} <- steps,
          do: env.payload["principal_id"]
    end

    assert reached(targets, offboarded, w, gate0) == targets
  end

  defp task_key(%{payload: %{"task_id" => t}} = env) when is_binary(t),
    do: Projection.task_key(env)

  defp task_key(_env), do: nil
end
