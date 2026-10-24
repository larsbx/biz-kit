defmodule TaskCore.AgentCandidatesTest do
  use ExUnit.Case, async: true

  alias TaskCore.AgentCandidates
  alias TaskCore.State

  defmodule TestHost do
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))
  end

  @request %{
    chapter_id: "chapter1",
    tenant_id: "tenant1",
    project_id: "project1",
    task_id: "task1",
    principal_id: "agent1",
    suggester_grant_event_id: "grant1"
  }

  defp event(id, type, payload) do
    %{
      event_id: id,
      type: type,
      chapter_id: "chapter1",
      payload: Map.merge(%{"tenant_id" => "tenant1", "project_id" => "project1"}, payload),
      signers: []
    }
  end

  defp ready_state do
    state = State.init(TestHost)

    state =
      State.handle_event(
        event("grant1", "TaskSuggesterGrantedV1", %{
          "principal_id" => "agent1",
          "key_id" => "agent-key",
          "pubkey" => {:bytes, <<1::256>>}
        }),
        state
      )

    state =
      State.handle_event(
        event("created1", "TaskCreatedV1", %{
          "task_id" => "task1",
          "title" => "Prepare a reviewed candidate",
          "timing" => %{"schedule" => nil, "due_ms" => nil}
        }),
        state
      )

    state =
      State.handle_event(
        event("definition1", "TaskDoDDefinedV1", %{
          "task_id" => "task1",
          "criteria" => [%{"id" => "review", "description" => "Independently review evidence"}]
        }),
        state
      )

    put_in(state, [:tasks, {"chapter1", "tenant1", "project1", "task1"}, :state], "ready")
  end

  test "derives only a scope-bound, content-free ticket from task projection" do
    state = ready_state()
    assert {:ok, ticket} = AgentCandidates.plan(state, @request)

    assert ticket == %{
             "chapter_id" => "chapter1",
             "tenant_id" => "tenant1",
             "project_id" => "project1",
             "task_id" => "task1",
             "task_version" => 2,
             "source_event_id" => "definition1",
             "definition_digest" =>
               Base.encode16(
                 :crypto.hash(
                   :sha256,
                   :erlang.term_to_binary([
                     %{"id" => "review", "description" => "Independently review evidence"}
                   ])
                 ),
                 case: :lower
               )
           }

    refute Map.has_key?(ticket, "principal_id")
    refute Map.has_key?(ticket, "title")
    assert :ok = AgentCandidates.current?(state, @request, ticket)
    assert state == ready_state()
  end

  test "rejects cross-tenant, cross-project and wrong agent principal" do
    state = ready_state()

    for change <- [
          %{tenant_id: "tenant2"},
          %{project_id: "project2"},
          %{principal_id: "agent2"}
        ] do
      assert {:error, _} = AgentCandidates.plan(state, Map.merge(@request, change))
    end
  end

  test "a revoked suggester grant refuses both new plans and old tickets" do
    state = ready_state()
    assert {:ok, ticket} = AgentCandidates.plan(state, @request)

    revoked =
      State.handle_event(
        state,
        event("revoke1", "TaskSuggesterRevokedV1", %{"authorization_event_id" => "grant1"})
      )

    assert {:error, :agent_grant_revoked} = AgentCandidates.plan(revoked, @request)

    assert {:error, :agent_grant_revoked} =
             AgentCandidates.current?(revoked, @request, ticket)
  end

  test "task changes invalidate pending candidate tickets" do
    state = ready_state()
    assert {:ok, ticket} = AgentCandidates.plan(state, @request)
    key = {"chapter1", "tenant1", "project1", "task1"}

    state = put_in(state, [:tasks, key, :version], 3)
    assert {:error, :stale_agent_ticket} = AgentCandidates.current?(state, @request, ticket)

    state = put_in(state, [:tasks, key, :last_event_id], "changed2")
    assert {:error, :stale_agent_ticket} = AgentCandidates.current?(state, @request, ticket)
  end

  test "completed, inbox and undefined DoD tasks cannot be dispatched" do
    state = ready_state()
    key = {"chapter1", "tenant1", "project1", "task1"}

    for status <- ~w(inbox completed cancelled proposed queued) do
      changed = put_in(state, [:tasks, key, :state], status)

      assert {:error, :task_not_ready_for_agent} =
               AgentCandidates.plan(changed, @request)
    end

    changed = put_in(state, [:tasks, key, :dod], nil)

    assert {:error, :task_definition_missing_or_invalid} =
             AgentCandidates.plan(changed, @request)
  end

  test "fail-closed on malformed digests, source IDs and incomplete snapshots" do
    state = ready_state()
    key = {"chapter1", "tenant1", "project1", "task1"}

    bad_digest = put_in(state, [:tasks, key, :dod, :definition_ref], {:bytes, <<0, 1>>})

    assert {:error, :task_definition_missing_or_invalid} =
             AgentCandidates.plan(bad_digest, @request)

    bad_source = put_in(state, [:tasks, key, :last_event_id], "../escape")
    assert {:error, :invalid_task_source} = AgentCandidates.plan(bad_source, @request)

    assert {:error, :invalid_replay_or_request} = AgentCandidates.plan(%{}, @request)

    assert {:error, :invalid_agent_request} =
             AgentCandidates.plan(state, Map.put(@request, :command, "complete"))

    assert {:error, :invalid_agent_request} =
             AgentCandidates.plan(state, %{@request | task_id: "../path"})
  end

  test "suggester grant does not become a delegation or task admission command" do
    state = ready_state()
    assert {:ok, ticket} = AgentCandidates.plan(state, @request)
    refute Map.has_key?(ticket, "authorization_event_id")
    refute Map.has_key?(ticket, "suggester_grant_event_id")
    refute Map.has_key?(ticket, "key_id")
    assert state.tasks[{"chapter1", "tenant1", "project1", "task1"}].state == "ready"
  end
end
