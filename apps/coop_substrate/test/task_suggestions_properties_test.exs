defmodule CoopSubstrate.TaskSuggestionsPropertiesTest do
  @moduledoc """
  The invariants of spec/task_suggestions.qnt as properties over generated
  histories. Histories run through the pure admission path the appender uses
  per event (`Envelope.verify/1`, `TypeRegistry.validity_check/2`, gate fold),
  so hundreds of them need no database.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import CoopSubstrate.LogCase, only: [new_member: 1]
  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.Projections.Membership, as: Gate
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

  @suggester_types ~w(TaskChangeSuggestedV1 TaskSuggestionWithdrawnV1 TaskSuggestionArtifactRecordedV1)
  @task_commands ~w(TaskCreatedV1 TaskTimingRevisedV1 TaskProposedV1)
  @t0 1_792_396_800_000
  @hour 3_600_000
  @tasks ~w(task-1 task-2)
  @kinds [["timing"], ["create"], ["timing", "create"]]
  # Inside the default delegation window (one week from @t0) unless noted.
  @timings [
    timed(@t0 + 2 * @hour),
    timed(@t0 + 5 * @hour, 2 * @hour),
    timed(@t0 + 8 * 24 * @hour),
    timed(@t0 + 3 * @hour, @hour, @t0),
    %{"schedule" => nil, "due_ms" => nil},
    %{
      "schedule" => %{
        "kind" => "timed",
        "start_ms" => @t0,
        "end_ms" => @t0 + 3_600_000,
        "tz" => "UTC"
      },
      "due_ms" => nil
    },
    %{
      "schedule" => %{
        "kind" => "all_day",
        "start_date" => "2026-10-19",
        "end_date" => "2026-10-20"
      },
      "due_ms" => @t0
    }
  ]

  setup_all do
    gov = new_member("governance")
    op = new_member("operator")
    agent = new_member("suggester")
    other = new_member("suggester")
    # Delegated commands are operator command types, signed by the agent's key.
    deleg = as_role(new_member("operator"), "operator")

    world = %{
      deleg: deleg,
      gov: gov,
      op: op,
      agent: agent,
      other: other,
      op_grant: operator_grant(gov, op, "alice"),
      agent_grant: suggester_grant(gov, agent, "bot"),
      other_grant: suggester_grant(gov, other, "bot-2"),
      digests: Enum.map(1..3, &store!("property artifact #{&1}"))
    }

    gate =
      [declare_governance(gov), world.op_grant, world.agent_grant, world.other_grant]
      |> Enum.reduce(Gate.init(), fn env, gate -> elem(admit(env, gate), 1) end)

    %{world: world, gate0: gate}
  end

  # -- generation --------------------------------------------------------------

  defp op_gen do
    idx = integer(0..5)

    frequency([
      {6, suggestion_op_gen(idx)},
      {2, tuple({constant(:delegate), idx, integer(1..3)})},
      {3, tuple({constant(:del_revise), idx, idx, idx})},
      {2, tuple({constant(:del_create), idx, idx, idx})},
      {1, tuple({constant(:revoke_delegation), idx})},
      {1, constant(:revoke_operator)}
    ])
  end

  defp suggestion_op_gen(idx) do
    one_of([
      tuple({constant(:create), idx, idx, one_of([constant(nil), idx])}),
      tuple({constant(:revise), idx, integer(-1..1), idx, one_of([constant(nil), idx])}),
      tuple({constant(:propose), idx}),
      tuple(
        {constant(:suggest_timing), idx, idx, integer(-1..1), boolean(),
         one_of([constant(nil), idx])}
      ),
      tuple({constant(:suggest_create), idx, idx}),
      tuple({constant(:withdraw), idx, boolean(), one_of([constant(nil), idx])}),
      tuple({constant(:decline), idx, one_of([constant(nil), idx])}),
      tuple({constant(:artifact), boolean(), idx}),
      tuple({constant(:custody), idx}),
      constant(:revoke_agent)
    ])
  end

  defp history_gen, do: list_of(op_gen(), max_length: 30)

  defp pick(list, i), do: if(list == [], do: nil, else: Enum.at(list, rem(i, length(list))))
  defp at(list, i), do: Enum.at(list, rem(i, length(list)))

  # Turn one generated op into an envelope against the current state.
  defp envelope(op, w, gate, seen) do
    tasks = gate.orchestration.tasks
    key = fn t -> {"chapter-genesis", "tenant-1", "project-1", t} end
    tv = fn t -> get_in(tasks, [key.(t), :timing_version]) || 0 end

    case op do
      {:create, t, timing, cite} ->
        sug = cite && pick(seen.sugs, cite)

        create(w.op, w.op_grant, at(@tasks, t), applied(sug, timing), suggestion: sug)

      {:revise, t, delta, timing, cite} ->
        task = at(@tasks, t)
        sug = cite && pick(seen.sugs, cite)

        revise(w.op, w.op_grant, task, tv.(task) + delta, applied(sug, timing), suggestion: sug)

      {:propose, t} ->
        task = at(@tasks, t)
        propose(w.op, w.op_grant, task, get_in(tasks, [key.(task), :version]) || 1)

      {:suggest_timing, t, timing, delta, by_other, receipt} ->
        {agent, grant} = if by_other, do: {w.other, w.other_grant}, else: {w.agent, w.agent_grant}
        task = at(@tasks, t)

        suggest(agent, grant, task, timing_change(at(@timings, timing)),
          base: tv.(task) + delta,
          rationale_receipt: receipt && pick(seen.agent_receipts, receipt)
        )

      {:suggest_create, t, timing} ->
        task = at(@tasks, t)
        suggest(w.agent, w.agent_grant, task, create_change("Task #{task}", at(@timings, timing)))

      {:withdraw, s, by_other, receipt} ->
        {agent, grant} = if by_other, do: {w.other, w.other_grant}, else: {w.agent, w.agent_grant}

        withdraw(agent, grant, pick(seen.sugs, s) || "no-suggestion",
          reason: "changed my mind",
          reason_receipt: receipt && pick(seen.agent_receipts, receipt)
        )

      {:decline, s, receipt} ->
        decline(w.op, w.op_grant, pick(seen.sugs, s) || "no-suggestion",
          reason: "not now",
          reason_receipt: receipt && pick(seen.agent_receipts ++ seen.op_receipts, receipt)
        )

      {:artifact, by_other, d} ->
        {agent, grant} = if by_other, do: {w.other, w.other_grant}, else: {w.agent, w.agent_grant}
        suggestion_artifact(agent, grant, at(w.digests, d))

      {:custody, d} ->
        custody(w.op, w.op_grant, at(w.digests, d))

      :revoke_agent ->
        suggester_revoke(w.gov, w.agent_grant)

      {:delegate, k, budget} ->
        delegation(w.op, w.op_grant, w.deleg, "deleg-bot", kinds: at(@kinds, k), budget: budget)

      {:del_revise, d, t, timing} ->
        task = at(@tasks, t)

        revise(
          w.deleg,
          pick(seen.delegations, d) || w.op_grant,
          task,
          tv.(task),
          at(@timings, timing)
        )

      {:del_create, d, t, timing} ->
        create(
          w.deleg,
          pick(seen.delegations, d) || w.op_grant,
          at(@tasks, t),
          at(@timings, timing)
        )

      {:revoke_delegation, d} ->
        revoke_delegation(w.op, w.op_grant, pick(seen.delegations, d) || w.op_grant)

      :revoke_operator ->
        operator_revoke(w.gov, w.op_grant)
    end
  end

  # An operator citing a suggestion applies its exact timing for even indexes,
  # so `accepted` stays reachable however large the timing pool grows.
  defp applied(%{payload: %{"change" => %{"timing" => timing}}}, i) when rem(i, 2) == 0,
    do: timing

  defp applied(_suggestion, i), do: at(@timings, i)

  defp admit(env, gate) do
    with :ok <- Envelope.verify(env),
         :ok <- TypeRegistry.validity_check(env, gate) do
      {:ok, Gate.handle_event(env, gate)}
    end
  end

  # Run a history; returns accepted envelopes and the gate after each one.
  defp run(ops, w, gate0) do
    seen = %{sugs: [], agent_receipts: [], op_receipts: [], delegations: []}

    {steps, gate, _seen} =
      Enum.reduce(ops, {[], gate0, seen}, fn op, {steps, gate, seen} ->
        env = envelope(op, w, gate, seen)

        case admit(env, gate) do
          {:ok, next} -> {[{env, gate, next} | steps], next, remember(seen, env)}
          {:error, _} -> {steps, gate, seen}
        end
      end)

    {Enum.reverse(steps), gate}
  end

  defp remember(seen, %{type: "TaskChangeSuggestedV1"} = env),
    do: %{seen | sugs: [env | seen.sugs]}

  defp remember(seen, %{type: "TaskSuggestionArtifactRecordedV1"} = env),
    do: %{seen | agent_receipts: [env | seen.agent_receipts]}

  defp remember(seen, %{type: "ArtifactCustodyRecordedV1"} = env),
    do: %{seen | op_receipts: [env | seen.op_receipts]}

  defp remember(seen, %{type: "TaskDelegationGrantedV1"} = env),
    do: %{seen | delegations: [env | seen.delegations]}

  defp remember(seen, _env), do: seen

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

  defp task_key(%{payload: %{"task_id" => t}} = env) when is_binary(t),
    do: Projection.task_key(env)

  defp task_key(_env), do: nil
end
