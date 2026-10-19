defmodule CoopSubstrate.TaskHistories do
  @moduledoc """
  Generated task histories for property tests: suggestions, delegations,
  revocations and lifecycle commands, run through the pure admission path the
  appender uses per event (`Envelope.verify/1`, `TypeRegistry.validity_check/2`,
  gate fold), so hundreds of them need no database. Most generated commands are
  deliberately invalid; `run/3` keeps the admitted ones.
  """

  use ExUnitProperties

  import CoopSubstrate.LogCase, only: [new_member: 1]
  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.Projections.Membership, as: Gate
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

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

  @doc "The signers and grants every history starts from, and the gate after them."
  def world do
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

    {world, gate}
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
      {1, constant(:revoke_operator)},
      {1, constant(:revoke_device)}
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

  def history_gen, do: list_of(op_gen(), max_length: 30)

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

      # The operator retires their own device: same effect, signed by its holder.
      :revoke_device ->
        device_revoke(w.op, w.op_grant, w.op_grant)
    end
  end

  # An operator citing a suggestion applies its exact timing for even indexes,
  # so `accepted` stays reachable however large the timing pool grows.
  defp applied(%{payload: %{"change" => %{"timing" => timing}}}, i) when rem(i, 2) == 0,
    do: timing

  defp applied(_suggestion, i), do: at(@timings, i)

  def admit(env, gate) do
    with :ok <- Envelope.verify(env),
         :ok <- TypeRegistry.validity_check(env, gate) do
      {:ok, Gate.handle_event(env, gate)}
    end
  end

  # Run a history; returns accepted envelopes and the gate after each one.
  def run(ops, w, gate0) do
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
end
