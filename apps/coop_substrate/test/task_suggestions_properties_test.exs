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
  @t0 1_792_396_800_000
  @tasks ~w(task-1 task-2)
  @timings [
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

    world = %{
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
        create(w.op, w.op_grant, at(@tasks, t), at(@timings, timing),
          suggestion: cite && pick(seen.sugs, cite)
        )

      {:revise, t, delta, timing, cite} ->
        task = at(@tasks, t)

        revise(w.op, w.op_grant, task, tv.(task) + delta, at(@timings, timing),
          suggestion: cite && pick(seen.sugs, cite)
        )

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
    end
  end

  defp admit(env, gate) do
    with :ok <- Envelope.verify(env),
         :ok <- TypeRegistry.validity_check(env, gate) do
      {:ok, Gate.handle_event(env, gate)}
    end
  end

  # Run a history; returns accepted envelopes and the gate after each one.
  defp run(ops, w, gate0) do
    seen = %{sugs: [], agent_receipts: [], op_receipts: []}

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

  test "generated histories reach every suggestion status", %{world: w, gate0: gate0} do
    statuses =
      history_gen()
      |> Enum.take(400)
      |> Enum.flat_map(fn ops ->
        {_steps, gate} = run(ops, w, gate0)
        Enum.map(gate.orchestration.suggestions, fn {_, s} -> s.status end)
      end)
      |> MapSet.new()

    assert statuses ==
             MapSet.new([:pending, :accepted, :amended, :declined, :withdrawn, :superseded])
  end

  defp task_key(%{payload: %{"task_id" => t}} = env) when is_binary(t),
    do: Projection.task_key(env)

  defp task_key(_env), do: nil
end
