defmodule CoopSubstrate.TaskDelegationTest do
  @moduledoc """
  Scenario tests for docs/architecture/2026-10-18-task-delegation.md through
  the real append path. Generated histories: `TaskSuggestionsPropertiesTest`;
  state machine: spec/task_suggestions.qnt.
  """
  use CoopSubstrate.LogCase, async: false

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Tasks, as: Projection

  @key {"chapter-genesis", "tenant-1", "project-1", "task-1"}
  @hour 3_600_000
  @day 24 * @hour

  setup do
    gov = new_member("governance")
    op = new_member("operator")
    # Delegated commands are the operator command types, signed by the agent.
    agent = as_role(new_member("operator"), "operator")
    op_grant = operator_grant(gov, op, "alice")
    {:ok, _} = Log.append([declare_governance(gov)])
    {:ok, _} = Log.append([op_grant, create(op, op_grant, "task-1", unscheduled())])
    %{gov: gov, op: op, agent: agent, op_grant: op_grant}
  end

  defp state, do: elem(Log.replay(Projection), 1)
  defp task(key \\ @key), do: state().tasks[key]
  defp rejected(env), do: Log.append([env])

  defp delegate!(ctx, opts \\ []) do
    d = delegation(ctx.op, ctx.op_grant, ctx.agent, "bot", opts)
    {:ok, _} = Log.append([d])
    d
  end

  # A timed slot inside the default window, `h` hours after it opens.
  defp slot(h, length \\ @hour, due \\ nil), do: timed(t0() + h * @hour, length, due)

  describe "delegated timing changes" do
    test "placing an unscheduled task in the window is applied and attributed", ctx do
      d = delegate!(ctx)

      {:ok, _} =
        Log.append([revise(ctx.agent, d, "task-1", 1, slot(2), rationale: "Free slot on Monday")])

      assert %{timing: timing, timing_version: 2, timing_delegation_id: id} = task()
      assert timing == slot(2)
      assert id == d.event_id
      assert %{used: 1, active: true} = state().delegations[d.event_id]
    end

    test "moving a block inside the window is allowed; leaving it is not", ctx do
      d = delegate!(ctx)
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 2, slot(30))])

      assert {:error, {:reject, 0, :delegation_outside_window}} =
               rejected(revise(ctx.agent, d, "task-1", 3, timed(t0() + 8 * @day)))

      assert {:error, {:reject, 0, :delegation_outside_window}} =
               rejected(revise(ctx.agent, d, "task-1", 3, timed(t0() - @hour)))
    end

    test "a block an operator placed outside the window cannot be pulled in", ctx do
      {:ok, _} = Log.append([revise(ctx.op, ctx.op_grant, "task-1", 1, timed(t0() + 9 * @day))])
      d = delegate!(ctx)

      assert {:error, {:reject, 0, :delegation_outside_window}} =
               rejected(revise(ctx.agent, d, "task-1", 2, slot(2)))
    end

    test "unscheduling and all-day schedules need approval", ctx do
      d = delegate!(ctx)
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])

      assert {:error, {:reject, 0, :delegation_outside_window}} =
               rejected(revise(ctx.agent, d, "task-1", 2, unscheduled()))

      assert {:error, {:reject, 0, :delegation_outside_window}} =
               rejected(revise(ctx.agent, d, "task-1", 2, all_day("2026-10-20", "2026-10-21")))
    end

    test "blocks longer than the delegated maximum need approval", ctx do
      d = delegate!(ctx, max_block_ms: 2 * @hour)

      assert {:error, {:reject, 0, :delegation_block_too_long}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2, 3 * @hour)))

      assert {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2, 2 * @hour))])
    end

    test "a due date is never set, changed or cleared under delegation", ctx do
      d = delegate!(ctx)
      due = t0() + 3 * @day

      assert {:error, {:reject, 0, :delegation_cannot_change_due}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2, @hour, due)))

      {:ok, _} = Log.append([revise(ctx.op, ctx.op_grant, "task-1", 1, slot(2, @hour, due))])

      # Keeping the operator's due date while moving the block is fine.
      assert {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 2, slot(5, @hour, due))])

      assert {:error, {:reject, 0, :delegation_cannot_change_due}} =
               rejected(revise(ctx.agent, d, "task-1", 3, slot(5)))
    end

    test "only the delegated task states may be changed", ctx do
      d = delegate!(ctx, states: ["inbox"])
      {:ok, _} = Log.append([propose(ctx.op, ctx.op_grant, "task-1", 1)])

      assert {:error, {:reject, 0, :delegation_state_not_allowed}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2)))
    end

    test "the default states are inbox and proposed", ctx do
      d = delegate!(ctx)
      {:ok, _} = Log.append([propose(ctx.op, ctx.op_grant, "task-1", 1)])
      assert {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])
    end

    test "a task list restricts which tasks may be changed", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-2", unscheduled())])
      d = delegate!(ctx, task_ids: ["task-2"])

      assert {:error, {:reject, 0, :delegation_task_not_allowed}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2)))

      assert {:ok, _} = Log.append([revise(ctx.agent, d, "task-2", 1, slot(2))])
    end

    test "an operator undo is an ordinary revision and clears the attribution", ctx do
      d = delegate!(ctx)
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])
      {:ok, _} = Log.append([revise(ctx.op, ctx.op_grant, "task-1", 2, unscheduled())])

      assert %{timing: timing, timing_version: 3, timing_delegation_id: nil} = task()
      assert timing == unscheduled()
    end
  end

  describe "delegated creation" do
    test "needs the create kind", ctx do
      d = delegate!(ctx)

      assert {:error, {:reject, 0, :delegation_kind_not_allowed}} =
               rejected(create(ctx.agent, d, "task-2", unscheduled()))
    end

    test "creates unscheduled or in-window tasks without a due date", ctx do
      d = delegate!(ctx, kinds: ["create"])
      {:ok, _} = Log.append([create(ctx.agent, d, "task-2", unscheduled())])
      {:ok, _} = Log.append([create(ctx.agent, d, "task-3", slot(4))])

      assert %{timing_delegation_id: id, timing_version: 1} =
               task({"chapter-genesis", "tenant-1", "project-1", "task-3"})

      assert id == d.event_id

      assert {:error, {:reject, 0, :delegation_cannot_change_due}} =
               rejected(create(ctx.agent, d, "task-4", %{unscheduled() | "due_ms" => t0()}))

      assert {:error, {:reject, 0, :delegation_outside_window}} =
               rejected(create(ctx.agent, d, "task-4", timed(t0() + 8 * @day)))
    end

    test "a create-only delegation cannot move blocks", ctx do
      d = delegate!(ctx, kinds: ["create"])

      assert {:error, {:reject, 0, :delegation_kind_not_allowed}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2)))
    end
  end

  describe "budget and revocation" do
    test "the budget caps admitted changes", ctx do
      d = delegate!(ctx, budget: 2)
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 2, slot(3))])

      assert {:error, {:reject, 0, :delegation_budget_exhausted}} =
               rejected(revise(ctx.agent, d, "task-1", 3, slot(4)))

      assert %{used: 2, budget: 2} = state().delegations[d.event_id]
    end

    test "rejected commands do not spend the budget", ctx do
      d = delegate!(ctx, budget: 1)
      {:error, _} = rejected(revise(ctx.agent, d, "task-1", 1, timed(t0() + 8 * @day)))
      assert {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])
    end

    test "the delegator revokes; nobody else can", ctx do
      d = delegate!(ctx)
      other = new_member("operator")
      other_grant = operator_grant(ctx.gov, other, "carol")
      {:ok, _} = Log.append([other_grant])

      assert {:error, {:reject, 0, :delegation_not_own}} =
               rejected(revoke_delegation(other, other_grant, d))

      {:ok, _} = Log.append([revoke_delegation(ctx.op, ctx.op_grant, d)])

      assert {:error, {:reject, 0, :delegation_already_revoked}} =
               rejected(revoke_delegation(ctx.op, ctx.op_grant, d))

      assert {:error, {:reject, 0, :delegation_revoked}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2)))
    end

    test "revoking the delegator's grant ends the delegation, and a re-grant does not revive it",
         ctx do
      d = delegate!(ctx)
      {:ok, _} = Log.append([operator_revoke(ctx.gov, ctx.op_grant)])

      assert {:error, {:reject, 0, :delegator_grant_revoked}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2)))

      {:ok, _} = Log.append([operator_grant(ctx.gov, ctx.op, "alice")])

      assert {:error, {:reject, 0, :delegator_grant_revoked}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2)))
    end

    test "past delegated changes stay after revocation", ctx do
      d = delegate!(ctx)
      {:ok, _} = Log.append([revise(ctx.agent, d, "task-1", 1, slot(2))])
      {:ok, _} = Log.append([revoke_delegation(ctx.op, ctx.op_grant, d)])
      assert task().timing == slot(2)
    end
  end

  describe "identity and scope of authority" do
    test "only the delegated key and principal may act", ctx do
      d = delegate!(ctx)
      stranger = as_role(new_member("operator"), "operator")

      assert {:error, {:reject, 0, :delegate_key_mismatch}} =
               rejected(revise(stranger, d, "task-1", 1, slot(2)))

      wrong_principal =
        revise(ctx.agent, d, "task-1", 1, slot(2))
        |> then(fn env ->
          signed_event(ctx.agent, env.type, %{env.payload | "principal_id" => "mallory"})
        end)

      assert {:error, {:reject, 0, :task_principal_mismatch}} = rejected(wrong_principal)
    end

    test "agents never resolve suggestions, so they cannot approve each other", ctx do
      suggester = new_member("suggester")
      sug_grant = suggester_grant(ctx.gov, suggester, "bot-2")
      sug = suggest(suggester, sug_grant, "task-1", timing_change(slot(2)), base: 1)
      d = delegate!(ctx)
      {:ok, _} = Log.append([sug_grant, sug])

      assert {:error, {:reject, 0, :delegated_cannot_resolve}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2), suggestion: sug))
    end

    test "lifecycle commands cannot be delegated", ctx do
      d = delegate!(ctx)

      assert {:error, {:reject, 0, :unknown_task_grant}} =
               rejected(propose(ctx.agent, d, "task-1", 1))
    end

    test "only an active operator can delegate", ctx do
      outsider = new_member("operator")
      fake_grant = operator_grant(ctx.gov, outsider, "eve")

      assert {:error, {:reject, 0, :unknown_task_grant}} =
               rejected(delegation(outsider, fake_grant, ctx.agent, "bot"))
    end
  end

  describe "delegation limits are validated" do
    test "every malformed limit is rejected with a named field", ctx do
      cases = [
        {:kinds, [kinds: []]},
        {:kinds, [kinds: ["timing", "timing"]]},
        {:kinds, [kinds: ["lifecycle"]]},
        {:window, [window: %{"not_before_ms" => 10, "not_after_ms" => 10}]},
        {:window, [window: %{"not_before_ms" => -1, "not_after_ms" => 10}]},
        {:window, [window: %{"not_before_ms" => 0}]},
        {:max_block_ms, [max_block_ms: 0]},
        {:max_block_ms, [max_block_ms: 32 * @day]},
        {:budget, [budget: 0]},
        {:budget, [budget: 10_001]},
        {:task_ids, [task_ids: []]},
        {:task_ids, [task_ids: ["task-1", "task-1"]]},
        {:task_ids, [task_ids: ["bad/segment"]]},
        {:states, [states: []]},
        {:states, [states: ["done"]]}
      ]

      for {field, opts} <- cases do
        assert {:error, {:reject, 0, {:invalid_delegation, ^field}}} =
                 rejected(delegation(ctx.op, ctx.op_grant, ctx.agent, "bot", opts)),
               "expected #{field} for #{inspect(opts)}"
      end
    end
  end

  describe "reasoning" do
    test "a delegated change cites the agent's own stored reasoning", ctx do
      d = delegate!(ctx)
      digest = store!("Tuesday 10:00 is the only free hour #{System.unique_integer()}")
      # Same key as the delegation, under the suggester role tag the artifact type requires.
      receipt = suggestion_artifact(as_role(ctx.agent, "suggester"), d, digest)
      {:ok, _} = Log.append([receipt])

      assert {:ok, _} =
               Log.append([
                 revise(ctx.agent, d, "task-1", 1, slot(2),
                   rationale: "Free hour",
                   rationale_receipt: receipt
                 )
               ])
    end

    test "rationale fields belong to delegated commands only", ctx do
      assert {:error, {:reject, 0, :rationale_requires_delegation}} =
               rejected(revise(ctx.op, ctx.op_grant, "task-1", 1, slot(2), rationale: "Because"))
    end

    test "a delegated rationale follows the suggestion rules", ctx do
      d = delegate!(ctx)

      assert {:error, {:reject, 0, :invalid_rationale}} =
               rejected(revise(ctx.agent, d, "task-1", 1, slot(2), rationale: " "))
    end
  end

  test "re-submitting a delegated command returns the original receipt", ctx do
    d = delegate!(ctx)
    cmd = revise(ctx.agent, d, "task-1", 1, slot(2))
    {:ok, [first]} = Log.append([cmd])
    assert {:ok, [^first]} = Log.append([cmd])
    assert %{used: 1} = state().delegations[d.event_id]
  end
end
