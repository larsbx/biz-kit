defmodule TaskCore.AccessTest do
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, State}
  alias TaskCore.Access, as: TaskAccess

  @key {"chapter", "tenant", "project", "task"}
  @pubkey <<7::256>>

  defp event(id, type, attrs) do
    %{
      event_id: id,
      type: type,
      chapter_id: "chapter",
      payload:
        Map.merge(
          %{"tenant_id" => "tenant", "project_id" => "project", "task_id" => "task"},
          attrs
        ),
      signers: [%{key_id: "gov-key", pubkey: @pubkey}]
    }
  end

  defp fixture do
    State.init(__MODULE__)
    |> put_in([:tasks, @key], %{version: 3, last_event_id: "source"})
  end

  defp grant(action, attrs \\ %{}) do
    event(
      "grant-" <> action,
      "TaskAccessGrantedV1",
      Map.merge(
        %{
          "principal_id" => "worker",
          "action" => action,
          "expected_task_version" => 3,
          "source_event_id" => "source"
        },
        attrs
      )
    )
  end

  defp check(env, state) do
    Admission.check(env, %{
      orchestration: state,
      role_keys: %{{"chapter", "governance"} => %{"gov-key" => @pubkey}}
    })
  end

  defp request(action \\ "read") do
    %{
      chapter_id: "chapter",
      tenant_id: "tenant",
      project_id: "project",
      task_id: "task",
      principal_id: "worker",
      grant_event_id: "grant-" <> action,
      action: action,
      task_version: 3,
      source_event_id: "source"
    }
  end

  test "read and execution grants are independent and never imply a write capability" do
    state = fixture()
    assert :ok = check(grant("read"), state)
    state = State.handle_event(grant("read"), state)
    assert :ok = TaskAccess.authorize(state, request())
    assert {:error, :unknown_task_access_grant} = TaskAccess.authorize(state, request("execute"))

    assert {:error, :task_access_action_mismatch} =
             TaskAccess.authorize(state, %{request() | action: "execute"})

    for action <- ["write", "complete", "tools", "*", "READ"] do
      assert {:error, :invalid_task_access_grant} = check(grant(action), state)
    end

    assert :ok = check(grant("execute"), state)
    state = State.handle_event(grant("execute"), state)
    assert :ok = TaskAccess.authorize(state, request("execute"))
    assert state.tasks == fixture().tasks
  end

  test "cross-tenant, project, chapter, task and principal substitutions fail closed" do
    state = State.handle_event(grant("read"), fixture())

    for field <- [:tenant_id, :project_id, :chapter_id, :task_id, :principal_id] do
      assert {:error, _} = TaskAccess.authorize(state, Map.put(request(), field, "other"))
    end

    assert {:error, :invalid_task_access_request} =
             TaskAccess.authorize(state, Map.put(request(), :untrusted, true))
  end

  test "task revision and source must match both the grant and current replay" do
    state = State.handle_event(grant("read"), fixture())

    assert {:error, :stale_task_access_revision} =
             TaskAccess.authorize(put_in(state, [:tasks, @key, :version], 4), request())

    assert {:error, :stale_task_access_revision} =
             TaskAccess.authorize(state, %{request() | source_event_id: "other"})

    assert {:error, :stale_task_access_revision} =
             check(grant("read", %{"expected_task_version" => 2}), fixture())
  end

  test "revocation and existing principal offboarding invalidate permissions" do
    state = State.handle_event(grant("read"), fixture())
    revoke = event("revoke", "TaskAccessRevokedV1", %{"grant_event_id" => "grant-read"})
    assert :ok = check(revoke, state)
    revoked = State.handle_event(revoke, state)
    assert {:error, :task_access_revoked} = TaskAccess.authorize(revoked, request())
    assert {:error, :task_access_revoked} = check(revoke, revoked)

    offboard = event("offboard", "TaskPrincipalOffboardedV1", %{"principal_id" => "worker"})
    assert :ok = check(offboard, state)

    assert {:error, :task_access_revoked} =
             TaskAccess.authorize(State.handle_event(offboard, state), request())
  end

  test "only declared governance can grant or revoke; duplicate and wrong-scope revokes fail" do
    state = fixture()
    rogue = %{grant("read") | signers: [%{key_id: "worker-key", pubkey: <<8::256>>}]}
    assert {:error, :task_governance_not_declared} = check(rogue, state)
    state = State.handle_event(grant("read"), state)
    assert {:error, :task_access_grant_already_recorded} = check(grant("read"), state)

    revoke =
      event("revoke", "TaskAccessRevokedV1", %{
        "task_id" => "other",
        "grant_event_id" => "grant-read"
      })

    assert {:error, :task_access_scope_mismatch} = check(revoke, state)
  end

  test "malformed and absent grants do not authorize even well-formed requests" do
    for changes <- [%{"expected_task_version" => true}, %{"principal_id" => "../escape"}] do
      assert {:error, :invalid_task_access_grant} = check(grant("read", changes), fixture())
    end

    assert {:error, :unknown_task_access_grant} = TaskAccess.authorize(fixture(), request())
    assert {:error, :invalid_task_access_request} = TaskAccess.authorize(%{}, request())
    assert {:error, :invalid_task_access_request} = TaskAccess.authorize(fixture(), nil)
  end

  test "accepted access commands remain immutable when permissions are revoked or offboarded" do
    read = grant("read")
    execute = grant("execute")
    state = Enum.reduce([read, execute], fixture(), &State.handle_event/2)
    assert state.task_access_commands == %{read.event_id => read, execute.event_id => execute}

    revoke = event("revoke", "TaskAccessRevokedV1", %{"grant_event_id" => read.event_id})
    state = State.handle_event(revoke, state)
    offboard = event("offboard", "TaskPrincipalOffboardedV1", %{"principal_id" => "worker"})
    state = State.handle_event(offboard, state)

    assert state.task_access_commands == %{
             read.event_id => read,
             execute.event_id => execute,
             revoke.event_id => revoke
           }

    for action <- ~w(read execute) do
      assert {:error, :task_access_revoked} = TaskAccess.authorize(state, request(action))
      assert {:error, :task_access_grant_already_recorded} = check(grant(action), state)
    end
  end
end
