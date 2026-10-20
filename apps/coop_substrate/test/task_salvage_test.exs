defmodule CoopSubstrate.TaskSalvageTest do
  @moduledoc """
  The SpruceGoose rules on the ledger
  (docs/architecture/2026-10-20-sprucegoose-salvage.md), signed by people's
  devices and replayed: todos and the completion they gate, a predecessor
  cycle refused across the project, and an SOP version that never goes back.
  The rules themselves are tested in `TaskCore.SalvageTest`.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.ExecutionFixtures

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  setup do: world!()

  test "a task completes only once its todos are done, and replay agrees", w do
    {:ok, _} = step(w, w.alice, {:add_todo, "task-1", "draft", "Draft the report", []})
    {:ok, _} = step(w, w.bob, {:add_todo, "task-1", "send", "Send it", ["draft"]})

    assert step(w, w.alice, {:complete_todo, "task-1", "send"}) ==
             {:error, {:invalid, :todo_dependencies_open}}

    ready!(w, "task-1")
    {:ok, _} = step(w, w.alice, {:start, "task-1"})
    {:ok, _} = evidence(w, "task-1", "The report")
    {:ok, accepted} = review(w, "task-1", "accept")

    assert step(w, w.alice, {:complete, "task-1", accepted.event_id}) ==
             {:error, {:invalid, :open_todos}}

    {:ok, _} = step(w, w.alice, {:complete_todo, "task-1", "draft"})
    {:ok, _} = step(w, w.bob, {:drop_todo, "task-1", "send", "Delivered by hand"})
    {:ok, _} = step(w, w.alice, {:complete, "task-1", accepted.event_id})

    assert %{state: "completed", todos: %{"send" => %{state: "dropped", principal_id: "bob"}}} =
             task("task-1")

    {:ok, replayed} = Log.replay(Membership)
    assert replayed.orchestration == Log.gate().orchestration
  end

  test "a readiness definition that closes a predecessor cycle is refused", w do
    queued!(w, "task-2", ["task-1"])
    {:ok, _} = step(w, w.alice, {:propose, "task-1"})

    assert {:error, {:reject, 0, :predecessor_cycle}} =
             Log.append(
               signed_event(w.gov, "TaskReadinessDefinedV1", %{
                 "tenant_id" => "tenant-1",
                 "project_id" => "project-1",
                 "task_id" => "task-1",
                 "expected_version" => task("task-1").version,
                 "artifact_requirements" => %{},
                 "predecessor_ids" => ["task-2"],
                 "sop_digest" => {:bytes, w.sop}
               })
             )
  end

  test "a versioned SOP never goes back", w do
    {:ok, _} = step(w, w.alice, {:propose, "task-1"})
    define = &readiness(w, "task-1", &1)

    {:ok, _} = define.("2.1.0")
    assert {:error, {:reject, 0, :sop_version_regressed}} = define.("2.0.9")
    assert {:error, {:reject, 0, :sop_version_required}} = define.(nil)
    assert {:ok, _} = define.("2.1.0")
    assert task("task-1").readiness.sop_version == "2.1.0"
  end

  defp readiness(w, id, version) do
    payload = %{
      "tenant_id" => "tenant-1",
      "project_id" => "project-1",
      "task_id" => id,
      "expected_version" => task(id).version,
      "artifact_requirements" => %{},
      "predecessor_ids" => [],
      "sop_digest" => {:bytes, w.sop}
    }

    payload = if version, do: Map.put(payload, "sop_version", version), else: payload
    Log.append(signed_event(w.gov, "TaskReadinessDefinedV1", payload))
  end
end
