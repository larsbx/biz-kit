defmodule CoopSubstrate.TaskTimingSuggestionsTest do
  @moduledoc """
  Scenario tests for docs/architecture/2026-10-18-task-timing-and-suggestions.md,
  through the real append path. Generated histories are covered by
  `TaskSuggestionsPropertiesTest`; the state machine by spec/task_suggestions.qnt.
  """
  use CoopSubstrate.LogCase, async: false

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{ArtifactCustody, Log}
  alias CoopSubstrate.Projections.Tasks, as: Projection

  @key {"chapter-genesis", "tenant-1", "project-1", "task-1"}
  @nine_am 1_792_396_800_000

  setup do
    gov = new_member("governance")
    op = new_member("operator")
    agent = new_member("suggester")
    op_grant = operator_grant(gov, op, "alice")
    agent_grant = suggester_grant(gov, agent, "bot")
    {:ok, _} = Log.append([declare_governance(gov)])
    {:ok, _} = Log.append([op_grant, agent_grant])
    %{gov: gov, op: op, agent: agent, op_grant: op_grant, agent_grant: agent_grant}
  end

  defp state, do: elem(Log.replay(Projection), 1)
  defp task(key \\ @key), do: state().tasks[key]
  defp suggestion(env), do: state().suggestions[env.event_id]
  defp rejected(env), do: Log.append([env])

  describe "TaskCreatedV1" do
    test "an operator creates an inbox task with its timing facet", ctx do
      {:ok, [created]} = Log.append([create(ctx.op, ctx.op_grant, "task-1", timed(@nine_am))])

      assert %{
               state: "inbox",
               version: 1,
               timing_version: 1,
               timing: timing,
               dod: nil,
               title: "Task task-1",
               last_event_id: last
             } = task()

      assert timing == timed(@nine_am)
      assert last == created.event_id
    end

    test "creation is refused for an existing task", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])

      assert {:error, {:reject, 0, :task_already_recorded}} =
               rejected(create(ctx.op, ctx.op_grant, "task-1", unscheduled()))
    end

    test "creation needs a nonempty title", ctx do
      assert {:error, {:reject, 0, :empty_task_field}} =
               rejected(create(ctx.op, ctx.op_grant, "task-1", unscheduled(), title: "  "))
    end

    test "an agent key cannot create, even under its own grant", ctx do
      # The suggester key is not the operator grant's key.
      assert {:error, {:reject, 0, :task_operator_key_mismatch}} =
               rejected(
                 create(as_role(ctx.agent, "operator"), ctx.op_grant, "task-1", unscheduled())
               )
    end
  end

  describe "timing validation" do
    test "every malformed timing is rejected with a named reason", ctx do
      cases = [
        {:schedule_order, put_in(timed(@nine_am), ["schedule", "end_ms"], @nine_am)},
        {:schedule_span, timed(@nine_am, 32 * 86_400_000)},
        {:negative_time, timed(-1)},
        {:timezone, put_in(timed(@nine_am), ["schedule", "tz"], "not a zone")},
        {:date_order, all_day("2026-10-21", "2026-10-19")},
        {:date_format, all_day("2026-10-19", "21/10/2026")},
        {:schedule_span, all_day("2026-01-01", "2027-01-03")},
        {:due, %{unscheduled() | "due_ms" => -5}},
        {:keys, Map.put(unscheduled(), "extra", 1)},
        {:keys, put_in(timed(@nine_am), ["schedule", "extra"], 1)},
        {:schedule_kind, %{unscheduled() | "schedule" => %{"kind" => "weekly"}}},
        {:keys, %{"schedule" => nil}}
      ]

      for {reason, timing} <- cases do
        assert {:error, {:reject, 0, {:invalid_task_timing, ^reason}}} =
                 rejected(create(ctx.op, ctx.op_grant, "task-1", timing)),
               "expected #{reason} for #{inspect(timing)}"
      end
    end

    test "all-day ranges are end-exclusive floating dates", ctx do
      assert {:ok, _} =
               Log.append([
                 create(ctx.op, ctx.op_grant, "task-1", all_day("2026-10-19", "2026-10-20"))
               ])
    end
  end

  describe "TaskTimingRevisedV1" do
    setup ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])
      :ok
    end

    test "revision replaces the whole timing and advances only the timing facet", ctx do
      {:ok, _} =
        Log.append([
          revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am, 1_800_000, @nine_am))
        ])

      assert %{timing: timing, timing_version: 2, version: 1} = task()
      assert timing == timed(@nine_am, 1_800_000, @nine_am)
    end

    test "a stale timing version is refused", ctx do
      {:ok, _} = Log.append([revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am))])

      assert {:error, {:reject, 0, {:stale_timing_version, 1, 2}}} =
               rejected(revise(ctx.op, ctx.op_grant, "task-1", 1, unscheduled()))
    end

    test "the lifecycle facet does not invalidate timing commands, nor the reverse", ctx do
      {:ok, _} = Log.append([propose(ctx.op, ctx.op_grant, "task-1", 1)])
      assert %{state: "proposed", version: 2, timing_version: 1} = task()

      {:ok, _} = Log.append([revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am))])
      assert %{state: "proposed", version: 2, timing_version: 2} = task()
    end

    test "revising an unknown task is refused", ctx do
      assert {:error, {:reject, 0, :unknown_task}} =
               rejected(revise(ctx.op, ctx.op_grant, "task-9", 1, unscheduled()))
    end
  end

  describe "suggestions" do
    setup ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])
      :ok
    end

    test "a suggestion enters the queue and changes no task state", ctx do
      before = task()
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug])

      assert task() == before

      assert %{
               status: :pending,
               task_id: "task-1",
               principal_id: "bot",
               base_timing_version: 1,
               resolved_by_event_id: nil
             } = suggestion(sug)
    end

    test "accepting the exact Δ resolves it as accepted", ctx do
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug])

      {:ok, [accept]} =
        Log.append([revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am), suggestion: sug)])

      assert %{status: :accepted, resolved_by_event_id: id} = suggestion(sug)
      assert id == accept.event_id
      assert task().timing == timed(@nine_am)
    end

    test "accepting with edits resolves it as amended", ctx do
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug])

      {:ok, _} =
        Log.append([
          revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am + 3_600_000), suggestion: sug)
        ])

      assert %{status: :amended} = suggestion(sug)
    end

    test "a suggestion resolves at most once", ctx do
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug, decline(ctx.op, ctx.op_grant, sug)])

      assert {:error, {:reject, 0, :suggestion_not_pending}} =
               rejected(
                 revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am), suggestion: sug)
               )

      assert {:error, {:reject, 0, :suggestion_not_pending}} =
               rejected(withdraw(ctx.agent, ctx.agent_grant, sug))
    end

    test "two resolutions of one suggestion in a single batch are refused", ctx do
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug])

      assert {:error, {:reject, 1, :suggestion_not_pending}} =
               Log.append([
                 decline(ctx.op, ctx.op_grant, sug),
                 withdraw(ctx.agent, ctx.agent_grant, sug)
               ])
    end

    test "a stale suggestion is admitted for review but cannot be applied blindly", ctx do
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)

      {:ok, _} =
        Log.append([sug, revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am + 7_200_000))])

      assert %{status: :pending, base_timing_version: 1} = suggestion(sug)
      assert task().timing_version == 2

      assert {:error, {:reject, 0, {:stale_timing_version, 1, 2}}} =
               rejected(
                 revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am), suggestion: sug)
               )

      assert {:ok, _} =
               Log.append([
                 revise(ctx.op, ctx.op_grant, "task-1", 2, timed(@nine_am), suggestion: sug)
               ])
    end

    test "a base ahead of the task is refused", ctx do
      assert {:error, {:reject, 0, :suggestion_base_ahead}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
                   base: 2
                 )
               )
    end

    test "a timing suggestion needs a base and an existing task", ctx do
      assert {:error, {:reject, 0, :suggestion_base_required}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()))
               )

      assert {:error, {:reject, 0, :unknown_task}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-9", timing_change(unscheduled()),
                   base: 1
                 )
               )
    end

    test "an invalid Δ is refused when suggested, not when accepted", ctx do
      bad = timing_change(put_in(timed(@nine_am), ["schedule", "end_ms"], 0))

      assert {:error, {:reject, 0, {:invalid_task_timing, :schedule_order}}} =
               rejected(suggest(ctx.agent, ctx.agent_grant, "task-1", bad, base: 1))

      assert {:error, {:reject, 0, {:invalid_suggestion_change, :kind}}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", %{"kind" => "delete"}, base: 1)
               )
    end

    test "a resolving command must match the suggestion's task and kind", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-2", unscheduled())])
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug])

      assert {:error, {:reject, 0, :suggestion_mismatch}} =
               rejected(
                 revise(ctx.op, ctx.op_grant, "task-2", 1, timed(@nine_am), suggestion: sug)
               )

      assert {:error, {:reject, 0, :suggestion_mismatch}} =
               rejected(create(ctx.op, ctx.op_grant, "task-3", unscheduled(), suggestion: sug))
    end

    test "rationale is a nonempty summary of at most 1,000 characters", ctx do
      for text <- ["", "   ", String.duplicate("x", 1001)] do
        assert {:error, {:reject, 0, :invalid_rationale}} =
                 rejected(
                   suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
                     base: 1,
                     rationale: text
                   )
                 )
      end

      assert {:ok, _} =
               Log.append([
                 suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
                   base: 1,
                   rationale: String.duplicate("x", 1000)
                 )
               ])
    end
  end

  describe "create suggestions" do
    test "accepting a create suggestion creates the task from its body", ctx do
      sug =
        suggest(
          ctx.agent,
          ctx.agent_grant,
          "task-1",
          create_change("Task task-1", timed(@nine_am))
        )

      {:ok, _} = Log.append([sug])
      refute task()

      {:ok, _} =
        Log.append([create(ctx.op, ctx.op_grant, "task-1", timed(@nine_am), suggestion: sug)])

      assert %{status: :accepted} = suggestion(sug)
    end

    test "creating the task without citing it supersedes, and records the creator as resolver",
         ctx do
      first = suggest(ctx.agent, ctx.agent_grant, "task-1", create_change("A", unscheduled()))
      second = suggest(ctx.agent, ctx.agent_grant, "task-1", create_change("B", unscheduled()))
      {:ok, _} = Log.append([first, second])

      {:ok, [created]} =
        Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled(), suggestion: first)])

      assert %{status: :amended} = suggestion(first)
      assert %{status: :superseded, resolved_by_event_id: id} = suggestion(second)
      assert id == created.event_id
    end

    test "a create suggestion for an existing task is refused", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])

      assert {:error, {:reject, 0, :task_already_recorded}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", create_change("A", unscheduled()))
               )
    end
  end

  describe "role separation" do
    test "operator keys cannot suggest and suggester keys cannot decide, even for one principal",
         ctx do
      # carol holds both grants, each bound to a different key.
      op_key = new_member("operator")
      agent_key = new_member("suggester")
      op_side = operator_grant(ctx.gov, op_key, "carol")
      sug_side = suggester_grant(ctx.gov, agent_key, "carol")
      {:ok, _} = Log.append([op_side, sug_side, create(op_key, op_side, "task-1", unscheduled())])

      assert {:error, {:reject, 0, :task_suggester_key_mismatch}} =
               rejected(
                 suggest(
                   as_role(op_key, "suggester"),
                   sug_side,
                   "task-1",
                   timing_change(unscheduled()), base: 1)
               )

      assert {:error, {:reject, 0, :task_operator_key_mismatch}} =
               rejected(
                 revise(as_role(agent_key, "operator"), op_side, "task-1", 1, unscheduled())
               )
    end

    test "an operator grant cannot authorise suggester events, nor the reverse", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])

      assert {:error, {:reject, 0, :unknown_suggester_grant}} =
               rejected(
                 suggest(
                   as_role(ctx.op, "suggester"),
                   ctx.op_grant,
                   "task-1",
                   timing_change(unscheduled()), base: 1)
               )

      assert {:error, {:reject, 0, :unknown_task_grant}} =
               rejected(
                 revise(
                   as_role(ctx.agent, "operator"),
                   ctx.agent_grant,
                   "task-1",
                   1,
                   unscheduled()
                 )
               )
    end

    test "revoking a suggester stops new suggestions but keeps its pending ones", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(timed(@nine_am)), base: 1)
      {:ok, _} = Log.append([sug, suggester_revoke(ctx.gov, ctx.agent_grant)])

      assert %{status: :pending} = suggestion(sug)

      assert {:error, {:reject, 0, :task_suggester_revoked}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
                   base: 1
                 )
               )

      assert {:ok, _} =
               Log.append([
                 revise(ctx.op, ctx.op_grant, "task-1", 1, timed(@nine_am), suggestion: sug)
               ])
    end

    test "only the suggesting principal may withdraw", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])
      other = new_member("suggester")
      other_grant = suggester_grant(ctx.gov, other, "bot-2")
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()), base: 1)
      {:ok, _} = Log.append([other_grant, sug])

      assert {:error, {:reject, 0, :suggestion_not_own}} =
               rejected(withdraw(other, other_grant, sug))

      assert {:ok, _} =
               Log.append([withdraw(ctx.agent, ctx.agent_grant, sug, reason: "Calendar changed")])

      assert %{status: :withdrawn, reason: "Calendar changed"} = suggestion(sug)
    end
  end

  describe "reasoning artifacts" do
    setup ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])
      :ok
    end

    test "an agent stores its full reasoning and cites it", ctx do
      digest =
        store!("Considered Tuesday; Thursday clashes with the review. #{System.unique_integer()}")

      {:ok, [receipt]} = Log.append([suggestion_artifact(ctx.agent, ctx.agent_grant, digest)])

      sug =
        suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
          base: 1,
          rationale_receipt: receipt
        )

      {:ok, _} = Log.append([sug])
      assert %{rationale_receipt_id: id} = suggestion(sug)
      assert id == receipt.event_id
    end

    test "the gate verifies the stored bytes", ctx do
      absent = :crypto.hash(:sha256, "never stored #{System.unique_integer()}")

      assert {:error, {:reject, 0, :not_found}} =
               rejected(suggestion_artifact(ctx.agent, ctx.agent_grant, absent))

      # 1 MiB cap for agent documents (operator custody allows 8 MiB).
      big = store!(:binary.copy("a", 1_048_576) <> "#{System.unique_integer()}")

      assert {:error, {:reject, 0, :artifact_too_large}} =
               rejected(suggestion_artifact(ctx.agent, ctx.agent_grant, big))
    end

    test "agent receipts never enter custody_receipts", ctx do
      digest = store!("agent notes #{System.unique_integer()}")
      {:ok, [receipt]} = Log.append([suggestion_artifact(ctx.agent, ctx.agent_grant, digest)])
      state = state()

      assert Map.has_key?(state.suggestion_artifacts, receipt.event_id)
      refute Map.has_key?(state.custody_receipts, receipt.event_id)

      # Every evidence, SOP and ready-input check resolves through custody_receipts.
      assert {:error, :unknown_custody_receipt} =
               ArtifactCustody.get(
                 state,
                 receipt.event_id,
                 {"chapter-genesis", "tenant-1", "project-1"}
               )
    end

    test "an operator re-records an agent document under their own authority", ctx do
      digest = store!("agent evidence #{System.unique_integer()}")
      {:ok, _} = Log.append([suggestion_artifact(ctx.agent, ctx.agent_grant, digest)])
      {:ok, [own]} = Log.append([custody(ctx.op, ctx.op_grant, digest)])

      assert Map.has_key?(state().custody_receipts, own.event_id)
    end

    test "an agent may cite only its own documents", ctx do
      other = new_member("suggester")
      other_grant = suggester_grant(ctx.gov, other, "bot-2")
      digest = store!("someone else's notes #{System.unique_integer()}")
      receipt = suggestion_artifact(other, other_grant, digest)
      {:ok, _} = Log.append([other_grant, receipt])

      assert {:error, {:reject, 0, :suggestion_artifact_not_own}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
                   base: 1,
                   rationale_receipt: receipt
                 )
               )

      op_digest = store!("operator custody #{System.unique_integer()}")
      {:ok, [op_receipt]} = Log.append([custody(ctx.op, ctx.op_grant, op_digest)])

      assert {:error, {:reject, 0, :unknown_suggestion_artifact}} =
               rejected(
                 suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
                   base: 1,
                   rationale_receipt: op_receipt
                 )
               )
    end

    test "an operator's decline reason must be operator custody", ctx do
      digest = store!("agent notes #{System.unique_integer()}")
      agent_receipt = suggestion_artifact(ctx.agent, ctx.agent_grant, digest)
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()), base: 1)
      {:ok, _} = Log.append([agent_receipt, sug])

      assert {:error, {:reject, 0, :unknown_custody_receipt}} =
               rejected(decline(ctx.op, ctx.op_grant, sug, reason_receipt: agent_receipt))

      op_digest = store!("why not #{System.unique_integer()}")
      {:ok, [op_receipt]} = Log.append([custody(ctx.op, ctx.op_grant, op_digest)])

      assert {:ok, _} =
               Log.append([
                 decline(ctx.op, ctx.op_grant, sug, reason: "Clashes", reason_receipt: op_receipt)
               ])

      assert %{status: :declined, reason: "Clashes", reason_receipt_id: id} = suggestion(sug)
      assert id == op_receipt.event_id
    end

    test "reasons survive closure", ctx do
      digest = store!("rationale #{System.unique_integer()}")
      receipt = suggestion_artifact(ctx.agent, ctx.agent_grant, digest)

      sug =
        suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()),
          base: 1,
          rationale_receipt: receipt
        )

      {:ok, _} = Log.append([receipt, sug, decline(ctx.op, ctx.op_grant, sug, reason: "Not now")])
      state = state()

      assert %{status: :declined, rationale_receipt_id: rid} = state.suggestions[sug.event_id]
      assert Map.has_key?(state.suggestion_artifacts, rid)
    end
  end

  describe "retry" do
    test "re-submitting the same signed envelope returns the original receipt", ctx do
      {:ok, _} = Log.append([create(ctx.op, ctx.op_grant, "task-1", unscheduled())])
      sug = suggest(ctx.agent, ctx.agent_grant, "task-1", timing_change(unscheduled()), base: 1)
      {:ok, [first]} = Log.append([sug])
      {:ok, _} = Log.append([suggester_revoke(ctx.gov, ctx.agent_grant)])

      assert {:ok, [^first]} = Log.append([sug])
    end
  end
end
