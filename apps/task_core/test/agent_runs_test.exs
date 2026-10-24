defmodule TaskCore.AgentRunsTest do
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, AgentRuns, State}

  defmodule Host do
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))
  end

  @task_key {"chapter1", "tenant1", "project1", "task1"}
  @run_key {"chapter1", "tenant1", "project1", "run1"}
  @criteria [%{"id" => "review", "description" => "Check agent candidate independently"}]
  @operator_pubkey <<2::256>>

  defp event(id, type, attrs) do
    %{
      event_id: id,
      type: type,
      chapter_id: "chapter1",
      payload: Map.merge(%{"tenant_id" => "tenant1", "project_id" => "project1"}, attrs),
      signers: [%{key_id: "operator-key", pubkey: @operator_pubkey}]
    }
  end

  defp fixture do
    state = State.init(Host)

    state =
      State.handle_event(
        event("opgrant1", "TaskOperatorGrantedV1", %{
          "principal_id" => "operator1",
          "key_id" => "operator-key",
          "pubkey" => {:bytes, @operator_pubkey}
        }),
        state
      )

    state =
      State.handle_event(
        event("sggrant1", "TaskSuggesterGrantedV1", %{
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
          "title" => "Review a candidate",
          "authorization_event_id" => "opgrant1",
          "timing" => %{"schedule" => nil, "due_ms" => nil}
        }),
        state
      )

    state =
      State.handle_event(
        event("definition1", "TaskDoDDefinedV1", %{
          "task_id" => "task1",
          "criteria" => @criteria
        }),
        state
      )

    # Test fixture creates a ready projection only; authoritative workflow
    # admission is independently tested by the ledger's existing lifecycle
    # tests. This is NOT an accepted signed ledger history.
    put_in(state, [:tasks, @task_key, :state], "ready")
  end

  defp requested(attrs \\ %{}) do
    event(
      "run-event1",
      "TaskAgentRunRequestedV1",
      Map.merge(
        %{
          "run_id" => "run1",
          "task_id" => "task1",
          "principal_id" => "operator1",
          "authorization_event_id" => "opgrant1",
          "agent_principal_id" => "agent1",
          "suggester_grant_event_id" => "sggrant1",
          "expected_task_version" => 2,
          "source_event_id" => "definition1",
          "definition_digest" => {:bytes, Host.hash(@criteria)},
          "execution_profile_id" => "approved-profile",
          "execution_profile_digest" => {:bytes, <<4::256>>},
          "max_duration_ms" => 30_000,
          "max_output_bytes" => 4096,
          "lifecycle_version" => 1
        },
        attrs
      )
    )
  end

  defp admitted?(command, state) do
    Admission.check(command, %{orchestration: state, role_keys: %{}})
  end

  defp with_run do
    state = fixture()
    command = requested()
    assert :ok = admitted?(command, state)
    {State.handle_event(command, state), command}
  end

  test "operator-signed request folds; runnable rechecks source and returns no signing material" do
    {state, command} = with_run()
    assert state.agent_runs[@run_key].status == :requested
    assert state.agent_run_commands[command.event_id] == command

    assert {:ok, execution} = AgentRuns.runnable?(state, @run_key)
    assert execution.intent_event_id == "run-event1"
    assert execution.ticket["task_version"] == 2
    assert execution.execution_profile_id == "approved-profile"
    assert execution.execution_profile_digest == {:bytes, <<4::256>>}
    refute Map.has_key?(execution.ticket, "authorization_event_id")
    refute Map.has_key?(execution.ticket, "suggester_grant_event_id")
    refute Map.has_key?(execution.ticket, "principal_id")
    assert state.tasks[@task_key].state == "ready"
  end

  test "independent agent engines use the same signed run event and lifecycle" do
    state = fixture()
    one = requested()

    two =
      requested(%{
        "run_id" => "run2",
        "execution_profile_id" => "hosted-agent",
        "execution_profile_digest" => {:bytes, <<8::256>>}
      })

    assert :ok = admitted?(one, state)
    state = State.handle_event(one, state)

    assert :ok = admitted?(two, state)
    state = State.handle_event(%{two | event_id: "run-event2"}, state)

    assert {:ok, local} = AgentRuns.runnable?(state, @run_key)

    assert {:ok, remote} =
             AgentRuns.runnable?(state, {"chapter1", "tenant1", "project1", "run2"})

    assert local.execution_profile_id == "approved-profile"
    assert remote.execution_profile_id == "hosted-agent"
    assert local.ticket == remote.ticket
    assert state.tasks[@task_key].state == "ready"
  end

  test "same run identifier cannot create a competing intent" do
    {state, _command} = with_run()

    assert {:error, :agent_run_id_already_used} =
             admitted?(%{requested() | event_id: "different"}, state)
  end

  test "wrong operator signing key is refused, even if the fields name an authorized operator" do
    command = requested()
    rogue = %{command | signers: [%{key_id: "agent-key", pubkey: <<1::256>>}]}
    assert {:error, :task_operator_key_mismatch} = admitted?(rogue, fixture())
  end

  test "agent principal, task version, digest and cross-tenant scope must match current replay" do
    for bad <- [
          %{"agent_principal_id" => "other"},
          %{"expected_task_version" => 3},
          %{"source_event_id" => "missing"},
          %{"definition_digest" => {:bytes, <<9::256>>}},
          %{"tenant_id" => "tenant2"},
          %{"project_id" => "project2"}
        ] do
      assert {:error, _} = admitted?(requested(bad), fixture())
    end
  end

  test "resource budgets and unapproved shapes fail closed" do
    for bad <- [
          %{"max_duration_ms" => 10_000_000},
          %{"max_output_bytes" => 100_000},
          %{"execution_profile_id" => "../escape"},
          %{"execution_profile_digest" => {:bytes, <<1>>}},
          %{"lifecycle_version" => 2}
        ] do
      assert {:error, :invalid_agent_run_request} = admitted?(requested(bad), fixture())
    end
  end

  test "revocation or offboarding after accepted intent blocks execution" do
    {state, _command} = with_run()

    revoked_agent =
      State.handle_event(
        event("revoked1", "TaskSuggesterRevokedV1", %{"authorization_event_id" => "sggrant1"}),
        state
      )

    assert {:error, :agent_grant_revoked} = AgentRuns.runnable?(revoked_agent, @run_key)

    revoked_operator =
      State.handle_event(
        event("revoked2", "TaskOperatorRevokedV1", %{"authorization_event_id" => "opgrant1"}),
        state
      )

    assert {:error, :agent_run_operator_revoked} =
             AgentRuns.runnable?(revoked_operator, @run_key)

    offboarded =
      State.handle_event(
        event("offboard1", "TaskPrincipalOffboardedV1", %{"principal_id" => "agent1"}),
        state
      )

    assert {:error, :agent_grant_revoked} = AgentRuns.runnable?(offboarded, @run_key)
  end

  test "task changes invalidate existing run" do
    {state, _command} = with_run()
    changed = put_in(state, [:tasks, @task_key, :version], 3)
    assert {:error, :stale_agent_run_task} = AgentRuns.runnable?(changed, @run_key)

    changed = put_in(state, [:tasks, @task_key, :state], "completed")

    assert {:error, :task_not_ready_for_agent} = AgentRuns.runnable?(changed, @run_key)
  end

  test "authorized cancellation updates replay, refuses old run, stale cancellation and duplicate" do
    {state, _command} = with_run()

    cancellation =
      event("cancel1", "TaskAgentRunCancelledV1", %{
        "run_id" => "run1",
        "principal_id" => "operator1",
        "authorization_event_id" => "opgrant1",
        "expected_run_version" => 1,
        "reason" => "No longer required"
      })

    assert :ok = admitted?(cancellation, state)
    cancelled = State.handle_event(cancellation, state)
    assert cancelled.agent_runs[@run_key].version == 2
    assert cancelled.agent_run_commands["cancel1"] == cancellation
    assert {:error, :agent_run_cancelled} = AgentRuns.runnable?(cancelled, @run_key)
    assert {:error, :agent_run_already_cancelled} = admitted?(cancellation, cancelled)

    assert {:error, :stale_agent_run_version} =
             admitted?(
               %{cancellation | payload: %{cancellation.payload | "expected_run_version" => 2}},
               state
             )
  end

  test "agent cannot self-cancel using suggester credentials" do
    {state, _command} = with_run()

    rogue =
      event("cancel2", "TaskAgentRunCancelledV1", %{
        "run_id" => "run1",
        "principal_id" => "agent1",
        "authorization_event_id" => "sggrant1",
        "expected_run_version" => 1,
        "reason" => "Bypass"
      })

    assert {:error, :unknown_task_grant} = admitted?(rogue, state)
  end

  test "cross-scope run key cannot be read as another tenant" do
    {state, _command} = with_run()

    assert {:error, :unknown_agent_run} =
             AgentRuns.runnable?(state, {"chapter1", "tenant2", "project1", "run1"})

    assert {:error, :invalid_agent_run_key} = AgentRuns.runnable?(state, "run1")
  end
end
