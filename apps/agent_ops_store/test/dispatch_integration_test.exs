defmodule AgentOpsStore.DispatchIntegrationTest do
  @moduledoc """
  Integration acceptance for the opt-in staging coordinator, real PostgreSQL
  CAS leases and two unrelated engine-neutral agent adapters. The fixture
  creates *trusted* TaskCore replay in memory; this test does not attest a
  signed ledger replay or grant a production execution entitlement.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias AgentOpsStore.{Coordinator, Postgres}
  alias TaskCore.State

  @task_key {"chapter1", "tenant1", "project1", "task1"}
  @criteria [%{"id" => "review", "description" => "Review the output independently"}]
  @opkey <<2::256>>

  defmodule FixtureHost do
    @behaviour TaskCore.Host
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))
    def verify_artifact(_, _), do: {:error, :unsupported_in_test}
    def read_blueprint(_), do: {:error, :unsupported_in_test}
  end

  defmodule LocalWorker do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort
    def launch(execution, _profile, effect_id) do
      Process.put(:launches, [{:local, execution.run_id, effect_id} | Process.get(:launches, [])])
      {:ok, %{id: "local-" <> execution.run_id}}
    end

    def poll(_handle), do: {:ok, %{state: :running}}
    def cancel(_handle, _reason), do: :ok
    def lookup(_profile, _effect), do: {:error, :reconciliation_not_available_in_fixture}
  end

  defmodule RemoteWorker do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort
    def launch(execution, _profile, effect_id) do
      Process.put(:launches, [{:remote, execution.run_id, effect_id} | Process.get(:launches, [])])
      {:ok, %{id: "remote-" <> execution.run_id}}
    end

    def poll(_handle), do: {:ok, %{state: :running}}
    def cancel(_handle, _reason), do: :ok
    def lookup(_profile, _effect), do: {:error, :reconciliation_not_available_in_fixture}
  end

  defmodule FailingReferenceWorker do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort
    def launch(execution, _profile, effect_id) do
      Process.put(:launches, [{:reference_failure, execution.run_id, effect_id} | Process.get(:launches, [])])
      {:ok, %{id: "bad-reference-" <> execution.run_id}}
    end

    def poll(_handle), do: {:ok, %{state: :running}}
    def cancel(_handle, _reason), do: :ok
    def lookup(_profile, _effect), do: {:error, :reconciliation_not_available_in_fixture}
  end

  defmodule Host do
    @behaviour AgentOpsStore.Host
    def environment, do: :staging

    def context(key) do
      current = Process.get(:fixture_state)
      if is_nil(current) or not Map.has_key?(current.agent_runs, key) do
        {:error, :unknown_agent_run}
      else
        ticks = Process.get(:context_reads, 0) + 1
        Process.put(:context_reads, ticks)
        if Process.get(:revoke_on_read) == ticks, do: Process.put(:fixture_state, revoke_read(current))

        {:ok,
         %{
           state: Process.get(:fixture_state),
           grants: %{read: "read1", execute: "execute1"},
           registry: Process.get(:registry),
           hash_manifest: &FixtureHost.hash/1,
           requirements: %{
             "features" => ["text", "idempotent_launch_v1", "effect_lookup_v1",
                            "cancellation_v1", "bounded_results_v1"],
             "data_classes" => ["internal"],
             "region" => "local",
             "max_duration_ms" => 30_000,
             "max_output_bytes" => 4096
           }
         }}
      end
    end

    defp revoke_read(state) do
      State.handle_event(
        %{
          event_id: "revoked-read",
          type: "TaskAccessRevokedV1",
          chapter_id: "chapter1",
          payload: %{
            "tenant_id" => "tenant1", "project_id" => "project1", "task_id" => "task1",
            "grant_event_id" => "read1"
          }
        },
        state
      )
    end

    def committed_state, do: {:ok, Process.get(:fixture_state)}
    def consent(_plan), do: :ok

    def reference(_plan, %{id: reference}) do
      if Process.get(:reject_reference) == true,
        do: {:error, :reference_not_persistable},
        else: {:ok, reference}
    end

    def request_termination(effect, reference) do
      Process.put(:terminations, [{effect, reference} | Process.get(:terminations, [])])
      :ok
    end

    def recovery_context(_), do: {:error, :independent_backend_verifier_required}
    def verify_observation(_, _), do: {:error, :independent_backend_verifier_required}
    def authenticate_execution(_), do: {:error, :no_external_credentials_in_fixture}
  end

  defp run_id(name), do: name <> "-" <> Process.get(:run_suffix)
  defp intent_id(name), do: "intent-" <> run_id(name)
  defp run_key(name), do: {"chapter1", "tenant1", "project1", run_id(name)}
  defp effect(name), do: "agent-run:" <> intent_id(name)

  defp event(id, type, attrs) do
    %{
      event_id: id, type: type, chapter_id: "chapter1",
      payload: Map.merge(%{"tenant_id" => "tenant1", "project_id" => "project1"}, attrs)
    }
  end

  defp test_state do
    state = State.init(FixtureHost)

    state =
      State.handle_event(
        event("operator1", "TaskOperatorGrantedV1", %{
          "principal_id" => "operator1", "key_id" => "operator-key",
          "pubkey" => {:bytes, @opkey}
        }),
        state
      )

    state =
      State.handle_event(
        event("suggester1", "TaskSuggesterGrantedV1", %{
          "principal_id" => "agent1", "key_id" => "agent-key",
          "pubkey" => {:bytes, <<3::256>>}
        }),
        state
      )

    state =
      State.handle_event(
        event("created1", "TaskCreatedV1", %{
          "task_id" => "task1", "title" => "Reviewed candidate",
          "timing" => %{"schedule" => nil, "due_ms" => nil}
        }),
        state
      )

    state =
      State.handle_event(
        event("definition1", "TaskDoDDefinedV1", %{
          "task_id" => "task1", "criteria" => @criteria
        }),
        state
      )

    state = put_in(state, [:tasks, @task_key, :state], "ready")

    state =
      Enum.reduce(["read", "execute"], state, fn action, current ->
        State.handle_event(
          event(action <> "1", "TaskAccessGrantedV1", %{
            "task_id" => "task1", "action" => action,
            "principal_id" => "agent1",
            "expected_task_version" => 2, "source_event_id" => "definition1"
          }),
          current
        )
      end)

    state
  end

  defp profile(id, backend) do
    manifest = %{
      "id" => id,
      "version" => 1,
      "adapter_module" => Atom.to_string(backend),
      "parameters" => %{
        "capabilities" => %{
          "features" => [
            "text", "idempotent_launch_v1", "effect_lookup_v1",
            "cancellation_v1", "bounded_results_v1"
          ],
          "data_classes" => ["internal"],
          "regions" => ["local"],
          "max_duration_ms" => 60_000,
          "max_output_bytes" => 8192
        },
        "backend" => id
      }
    }

    %{id: id, approved: true, adapter: backend, manifest: manifest}
  end

  defp with_run(state, id, name) do
    p = Process.get(:registry)[name]

    State.handle_event(
      event(intent_id(id), "TaskAgentRunRequestedV1", %{
        "run_id" => run_id(id), "task_id" => "task1",
        "principal_id" => "operator1", "authorization_event_id" => "operator1",
        "agent_principal_id" => "agent1", "suggester_grant_event_id" => "suggester1",
        "expected_task_version" => 2, "source_event_id" => "definition1",
        "definition_digest" => {:bytes, FixtureHost.hash(@criteria)},
        "execution_profile_id" => name,
        "execution_profile_digest" => {:bytes, FixtureHost.hash(p.manifest)},
        "max_duration_ms" => 30_000, "max_output_bytes" => 4096,
        "lifecycle_version" => 1
      }),
      state
    )
  end

  setup do
    Process.put(:run_suffix, Base.encode16(:crypto.strong_rand_bytes(5), case: :lower))
    Process.put(:launches, [])
    Process.put(:terminations, [])
    Process.put(:context_reads, 0)
    Process.delete(:revoke_on_read)
    Process.delete(:reject_reference)

    profiles = %{
      "local" => profile("local", LocalWorker),
      "remote" => profile("remote", RemoteWorker),
      "ambiguous" => profile("ambiguous", FailingReferenceWorker)
    }

    Process.put(:registry, profiles)
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})
    state = test_state()
    state = with_run(state, "run1", "local")
    state = with_run(state, "run2", "remote")
    state = with_run(state, "run3", "ambiguous")
    Process.put(:fixture_state, state)

    %{conn: conn}
  end

  test "two unrelated adapters share durable signed-intent delivery, without duplicate launch", %{conn: conn} do
    assert {:ok, %{disposition: :dispatched, backend_ref: "local-" <> run_id("run1"), lease: lease}} =
             Coordinator.deliver(conn, run_key("run1"), Host, "worker1")
    assert lease.epoch == 1

    assert {:ok, %{disposition: :already_dispatched}} =
             Coordinator.deliver(conn, run_key("run1"), Host, "worker2")

    assert {:ok, %{disposition: :dispatched, backend_ref: "remote-" <> run_id("run2")}} =
             Coordinator.deliver(conn, run_key("run2"), Host, "worker2")

    assert Enum.count(Process.get(:launches)) == 2
    assert {:ok, row} = Postgres.snapshot(conn, effect("run1"))
    assert row.phase == "leased" and row.backend_ref == "local-" <> run_id("run1")
    assert {:ok, row} = Postgres.snapshot(conn, effect("run2"))
    assert row.phase == "leased" and row.backend_ref == "remote-" <> run_id("run2")
    assert row.epoch == 1
  end

  test "grant revoked after claim fences execution without invoking the adapter", %{conn: conn} do
    # First stage is prepare, second stage is after durable CAS claim.
    Process.put(:revoke_on_read, 2)
    assert {:error, :authority_changed_after_claim} =
             Coordinator.deliver(conn, run_key("run1"), Host, "worker1")

    assert Process.get(:launches) == []
    assert {:ok, row} = Postgres.snapshot(conn, effect("run1"))
    assert row.phase == "cancel_requested"
  end

  test "ambiguous launch acknowledgment remains leased, never automatically retried", %{conn: conn} do
    Process.put(:reject_reference, true)
    key = run_key("run3")

    assert {:error, :launch_requires_reconciliation} =
             Coordinator.deliver(conn, key, Host, "worker1")

    assert [{:reference_failure, "run3", effect("run3")}] = Process.get(:launches)

    assert {:ok, row} = Postgres.snapshot(conn, effect("run3"))
    assert row.phase == "leased"
    assert row.backend_ref == nil

    assert {:ok, %{disposition: :already_dispatched}} =
             Coordinator.deliver(conn, key, Host, "worker2")

    assert length(Process.get(:launches)) == 1
  end

  test "revoked execution grant fences an existing backend and requests termination", %{conn: conn} do
    assert {:ok, %{disposition: :dispatched}} =
             Coordinator.deliver(conn, run_key("run1"), Host, "worker1")

    current = Process.get(:fixture_state)
    revoked =
      State.handle_event(
        event("revoked-execute", "TaskAccessRevokedV1", %{
          "task_id" => "task1", "grant_event_id" => "execute1"
        }),
        current
      )

    Process.put(:fixture_state, revoked)
    assert {:ok, :cancel_requested} = Coordinator.withdraw(conn, run_key("run1"), Host)

    assert {:ok, row} = Postgres.snapshot(conn, effect("run1"))
    assert row.phase == "cancel_requested"
    assert [{effect("run1"), "local-" <> run_id("run1")}] = Process.get(:terminations)

    assert {:error, _} = Coordinator.prepare(run_key("run1"), Host)
  end
end
