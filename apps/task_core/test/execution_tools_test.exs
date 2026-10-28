defmodule TaskCore.ExecutionToolsTest do
  use ExUnit.Case, async: true
  alias TaskCore.{ExecutionTools, State}
  @key {"chapter", "tenant", "project", "task"}
  @request %{
    chapter_id: "chapter",
    tenant_id: "tenant",
    project_id: "project",
    task_id: "task",
    principal_id: "worker",
    grant_event_id: "read-1",
    action: "read",
    task_version: 3,
    source_event_id: "source-3"
  }

  defp state do
    State.init(__MODULE__)
    |> put_in([:tasks, @key], %{
      title: "Task",
      description: "Input",
      version: 3,
      last_event_id: "source-3",
      state: "ready",
      private_credentials: "never disclose",
      dod: %{submission: "private evidence"}
    })
    |> put_in([:task_access_grants, "read-1"], %{
      active: true,
      task_key: @key,
      principal_id: "worker",
      action: "read",
      task_version: 3,
      source_event_id: "source-3"
    })
  end

  test "only explicitly allowed task fields are disclosed, never credentials or evidence" do
    assert {:ok, view} = ExecutionTools.read_task(state(), "worker", @request)
    assert view == %{title: "Task", description: "Input", version: 3, state: "ready"}
    refute Map.has_key?(view, :dod)
    refute Map.has_key?(view, :private_credentials)
  end

  test "authenticated identity is independent of the caller's principal field" do
    assert {:error, :task_access_principal_mismatch} =
             ExecutionTools.read_task(state(), "other", @request)
  end

  test "revocation, stale versions and cross-tenant input cannot disclose a task" do
    revoked = put_in(state(), [:task_access_grants, "read-1", :active], false)
    assert {:error, :task_access_revoked} = ExecutionTools.read_task(revoked, "worker", @request)

    for change <- [%{tenant_id: "other"}, %{task_version: 4}, %{grant_event_id: "unknown"}] do
      assert {:error, _} =
               ExecutionTools.read_task(state(), "worker", Map.merge(@request, change))
    end
  end

  test "execute or write actions cannot be smuggled into the read tool" do
    for action <- ["execute", "write", "complete"] do
      assert {:error, :task_access_action_mismatch} =
               ExecutionTools.read_task(state(), "worker", %{@request | action: action})
    end
  end
end
