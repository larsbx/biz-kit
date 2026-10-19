defmodule CoopSubstrate.CancelReopenTest do
  @moduledoc """
  Calling a task off (docs/architecture/2026-10-19-cancel-reopen.md): a
  person cancels before the work starts, governance at any state short of
  completed, both with a reason, and cancelled is final; a task under way
  can be sent back to queued, clearing the work, to be readied again.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.{ExecutionFixtures, TaskTimingFixtures}

  alias CoopSubstrate.{Cancellation, Crypto, Log}
  alias CoopSubstrate.Cancellation.Canceller

  setup do: world!()

  defp cancel(w, id, who \\ nil), do: step(w, who || w.alice, {:cancel, id, "Not needed"})

  defp started!(w, id) do
    ready!(w, id)
    {:ok, _} = step(w, w.alice, {:start, id})
  end

  # As `mix coop.cancel` does, without the HTTP between.
  defp governance_cancel(w, id, reason \\ "Client withdrew") do
    key = {"chapter-genesis", "tenant-1", "project-1", id}

    with {:ok, pending} <- Cancellation.prepare(key, reason, w.gov.signer.key_id) do
      Cancellation.cancel(key, pending.id, Crypto.sign(pending.signing_bytes, w.gov.seed))
    end
  end

  test "a person cancels before the work starts, with a reason; cancelled is final", w do
    assert {:ok, %{type: "TaskCancelledV1"} = cancelled} = cancel(w, "task-1")

    assert %{state: "cancelled", cancellation: %{principal_id: "alice", reason: "Not needed"}} =
             task("task-1")

    assert task("task-1").cancellation.event_id == cancelled.event_id

    assert cancel(w, "task-1") ==
             {:error, {:invalid, {:invalid_task_transition, "cancelled", "cancelled"}}}

    assert step(w, w.alice, {:propose, "task-1"}) ==
             {:error, {:invalid, {:invalid_task_transition, "cancelled", "proposed"}}}

    assert step(w, w.alice, {:cancel, "task-2", " "}) == {:error, {:invalid, :invalid_reason}}
  end

  test "each state before the work starts can be cancelled by a person, not once started", w do
    {:ok, _} = cancel(w, "task-2")

    for {id, setup} <- [
          {"t-proposed", &proposed!(&1, &2, [])},
          {"t-queued", &queued!(&1, &2)},
          {"t-ready", &ready!(&1, &2)}
        ] do
      {:ok, _} = Log.append(create(elem(w.alice, 1), w.alice_grant, id, unscheduled()))
      setup.(w, id)
      assert {:ok, _} = cancel(w, id)
    end

    started!(w, "task-1")

    assert cancel(w, "task-1") ==
             {:error, {:invalid, {:invalid_task_transition, "in_progress", "cancelled"}}}
  end

  test "governance cancels work under way, never a completed task", w do
    started!(w, "task-1")
    assert {:ok, %{type: "TaskCancelledByGovernanceV1"}} = governance_cancel(w, "task-1")

    assert %{state: "cancelled", cancellation: %{principal_id: nil, reason: "Client withdrew"}} =
             task("task-1")

    started!(w, "task-2")
    {:ok, _} = evidence(w, "task-2", "The report")
    {:ok, accepted} = review(w, "task-2", "accept")
    {:ok, _} = step(w, w.alice, {:complete, "task-2", accepted.event_id})

    assert governance_cancel(w, "task-2") ==
             {:error, {:invalid, {:invalid_task_transition, "completed", "cancelled"}}}

    assert governance_cancel(w, "nope") == {:error, :unknown_task}
  end

  test "the administrator's tool signs exactly that task's cancellation, with that reason" do
    key = {"chapter-genesis", "tenant-1", "project-1", "task-1"}

    core = %{
      "type" => "TaskCancelledByGovernanceV1",
      "chapter_id" => "chapter-genesis",
      "payload" => %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "task_id" => "task-1",
        "expected_version" => 3,
        "reason" => "Client withdrew"
      }
    }

    assert Canceller.cancels?(core, key, "Client withdrew")
    refute Canceller.cancels?(core, key, "Other reason")
    refute Canceller.cancels?(core, put_elem(key, 3, "task-2"), "Client withdrew")
    refute Canceller.cancels?(%{core | "type" => "TaskCancelledV1"}, key, "Client withdrew")
  end

  test "a cancelled successor's predecessor: the successor waits until governance redefines it",
       w do
    {:ok, _} = cancel(w, "task-1")
    queued!(w, "task-2", ["task-1"])

    assert step(w, w.alice, {:ready, "task-2", %{"input" => w.input_receipt}}) ==
             {:error, {:invalid, :incomplete_predecessors}}

    governance(w, "task-2", "TaskReadinessDefinedV1", %{
      "artifact_requirements" => %{"input" => {:bytes, w.input}},
      "predecessor_ids" => [],
      "sop_digest" => {:bytes, w.sop}
    })

    {:ok, _} = step(w, w.alice, {:acknowledge_sop, "task-2", w.sop_receipt})
    assert {:ok, _} = step(w, w.alice, {:ready, "task-2", %{"input" => w.input_receipt}})
  end

  test "cancelling ends pending timing suggestions, and the task is not rescheduled", w do
    agent = new_member("suggester")
    {:ok, [grant]} = Log.append(suggester_grant(w.gov, agent, "bot"))

    {:ok, [s]} =
      Log.append(
        suggest(agent, grant, "task-1", timing_change(%{"schedule" => nil, "due_ms" => 1}),
          base: 1
        )
      )

    {:ok, cancelled} = cancel(w, "task-1")

    assert %{status: :superseded, resolved_by_event_id: id} =
             Log.gate().orchestration.suggestions[s.event_id]

    assert id == cancelled.event_id

    assert {:error, {:reject, _, :task_cancelled}} =
             Log.append(
               suggest(agent, grant, "task-1", timing_change(%{"schedule" => nil, "due_ms" => 2}),
                 base: 1
               )
             )

    assert {:error, {:reject, _, :task_cancelled}} =
             Log.append(
               revise(elem(w.alice, 1), w.alice_grant, "task-1", 1, %{
                 "schedule" => nil,
                 "due_ms" => 3
               })
             )
  end

  test "a task under way goes back to queued, its work cleared, and is readied again", w do
    started!(w, "task-1")
    {:ok, _} = evidence(w, "task-1", "A start")
    {:ok, _} = review(w, "task-1", "refuse")

    assert step(w, w.alice, {:reopen, "task-1", ""}) == {:error, {:invalid, :invalid_reason}}
    assert {:ok, %{type: "TaskReopenedV1"}} = step(w, w.bob, {:reopen, "task-1", "Wrong input"})

    assert %{state: "queued", started_by: nil, dod: %{submission: nil, review: nil}} =
             task("task-1")

    assert step(w, w.alice, {:reopen, "task-1", "Again"}) ==
             {:error, {:invalid, {:invalid_task_transition, "queued", "queued"}}}

    assert {:ok, _} = step(w, w.alice, {:ready, "task-1", %{"input" => w.input_receipt}})
    assert {:ok, _} = step(w, w.alice, {:start, "task-1"})
  end
end
