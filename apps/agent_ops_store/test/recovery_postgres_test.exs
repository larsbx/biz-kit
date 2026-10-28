defmodule AgentOpsStore.RecoveryPostgresTest do
  @moduledoc "Storage/host integration with synthetic backend proofs; NOT real backend conformance."
  use ExUnit.Case, async: false
  @moduletag :integration
  alias AgentOpsStore.{Coordinator, Postgres, ToolProxy}

  defmodule FixtureAdapter do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort
    def launch(_, _, effect) do
      Process.put(:launches, Process.get(:launches, 0) + 1)
      {:ok, "backend:" <> effect}
    end

    def poll(_), do: {:error, :fixture_only}
    def cancel(_, _), do: :ok
    def lookup(_, _), do: {:ok, Process.get(:observation, %{state: :unknown})}
  end

  defmodule FixtureHost do
    @behaviour AgentOpsStore.Host
    def environment, do: :staging
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))
    def context(_), do: {:ok, Process.get(:context)}
    def committed_state, do: {:ok, Process.get(:context).state}
    def consent(_), do: Process.get(:consent, :ok)

    def authenticate_execution(:fixture_credential),
      do: {:ok, Process.get(:authenticated_identity)}

    def authenticate_execution(_), do: {:error, :unauthenticated_execution}
    def reference(_, handle), do: {:ok, handle}

    def request_termination(_, _) do
      Process.put(:termination_requested, true)
      :ok
    end

    def recovery_context(_) do
      context = Process.get(:context)
      {:ok, %{registry: context.registry, hash_manifest: &hash/1}}
    end

    def verify_observation(row, raw) do
      if raw[:trusted_fixture] == true and (raw[:state] != :candidate or raw[:on_time] == true) do
        receipt = :erlang.term_to_binary({row.effect_id, row.epoch, raw})

        {:ok,
         Map.merge(
           %{
             effect_id: row.effect_id,
             epoch: row.epoch,
             verified: true,
             final: true,
             receipt: receipt,
             within_budget: raw[:on_time] == true
           },
           raw
         )}
      else
        {:error, :unverified_backend_outcome}
      end
    end
  end

  setup do
    conn = start_supervised!({Postgrex, AgentOpsStore.TestConnection.options()})
    unique = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    key = {"chapter", "tenant", "project", "run-" <> unique}

    features =
      ~w(text task_read_v1 idempotent_launch_v1 effect_lookup_v1 cancellation_v1 bounded_results_v1)

    profile = %{
      id: "approved",
      approved: true,
      adapter: FixtureAdapter,
      manifest: %{
        "id" => "approved",
        "version" => 1,
        "adapter_module" => Atom.to_string(FixtureAdapter),
        "parameters" => %{
          "capabilities" => %{
            "features" => features,
            "data_classes" => ["internal"],
            "regions" => ["local"],
            "max_duration_ms" => 30000,
            "max_output_bytes" => 4096
          }
        }
      }
    }

    task_key = {"chapter", "tenant", "project", "task"}

    base_grant = %{
      active: true,
      chapter_id: "chapter",
      tenant_id: "tenant",
      project_id: "project"
    }

    access =
      Map.merge(base_grant, %{
        principal_id: "agent",
        task_key: task_key,
        task_version: 3,
        source_event_id: "source"
      })

    run = %{
      status: :requested,
      version: 1,
      intent_event_id: "intent-" <> unique,
      operator_grant_id: "op",
      agent_principal_id: "agent",
      suggester_grant_event_id: "sg",
      task_id: "task",
      expected_task_version: 3,
      source_event_id: "source",
      definition_digest: {:bytes, <<2::256>>},
      execution_profile_id: "approved",
      execution_profile_digest: {:bytes, FixtureHost.hash(profile.manifest)},
      max_duration_ms: 30000,
      max_output_bytes: 4096
    }

    state =
      TaskCore.State.init(__MODULE__)
      |> put_in([:tasks, task_key], %{
        title: "Scoped input",
        state: "ready",
        version: 3,
        last_event_id: "source",
        dod: %{definition_ref: {:bytes, <<2::256>>}},
        credentials: "private",
        evidence: "private"
      })
      |> put_in([:grants, "op"], Map.put(base_grant, :principal_id, "operator"))
      |> put_in([:suggester_grants, "sg"], Map.put(base_grant, :principal_id, "agent"))
      |> put_in([:task_access_grants, "read"], Map.put(access, :action, "read"))
      |> put_in([:task_access_grants, "execute"], Map.put(access, :action, "execute"))
      |> put_in([:agent_runs, key], run)

    Process.put(:context, %{
      state: state,
      grants: %{read: "read", execute: "execute"},
      registry: %{"approved" => profile},
      hash_manifest: &FixtureHost.hash/1,
      requirements: %{
        "features" => features,
        "data_classes" => ["internal"],
        "region" => "local",
        "max_duration_ms" => 30000,
        "max_output_bytes" => 4096
      }
    })

    Process.put(:launches, 0)
    {:ok, plan} = Coordinator.prepare(key, FixtureHost)
    %{conn: conn, key: key, plan: plan}
  end

  defp expire(conn, effect) do
    Postgrex.query!(
      conn,
      "UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE effect_id=$1",
      [effect]
    )
  end

  defp revoke_read do
    context = Process.get(:context)
    Process.put(:context, put_in(context, [:state, :task_access_grants, "read", :active], false))
  end

  test "crash after backend create but before attachment adopts without duplicate launch", c do
    assert {:ok, :new} = Postgres.register(c.conn, c.plan)
    assert {:ok, old_lease} = Postgres.claim(c.conn, c.plan.effect_id, 1, "lost-worker", 5000, 2)
    {:ok, reference} = FixtureAdapter.launch(c.plan.execution, c.plan.profile, c.plan.effect_id)
    expire(c.conn, c.plan.effect_id)
    Process.put(:observation, %{state: :running, backend_ref: reference, trusted_fixture: true})

    assert {:ok, %{epoch: 2, phase: "leased"}} =
             Coordinator.recover(c.conn, c.key, FixtureHost, "recovery-worker")

    assert Process.get(:launches) == 1
    assert {:ok, row} = Postgres.snapshot(c.conn, c.plan.effect_id)
    assert row.attempts == 1
    assert row.backend_ref == reference

    assert {:error, :transition_refused} =
             Postgres.renew(c.conn, c.plan.effect_id, row.version, 1, old_lease.token, 5000)

    assert {:ok, %{disposition: :already_dispatched}} =
             Coordinator.deliver(c.conn, c.key, FixtureHost, "other-worker")

    assert Process.get(:launches) == 1
  end

  test "candidate bytes are atomic, scoped, bounded and cannot be overwritten by stale delivery",
       c do
    {:ok, delivery} = Coordinator.deliver(c.conn, c.key, FixtureHost, "worker")

    assert {:error, :candidate_too_large_or_invalid} =
             Coordinator.submit_candidate(
               c.conn,
               c.key,
               FixtureHost,
               delivery.lease,
               :binary.copy("x", 4097)
             )

    assert {:ok, receipt} =
             Coordinator.submit_candidate(c.conn, c.key, FixtureHost, delivery.lease, "candidate")

    assert receipt.digest == :crypto.hash(:sha256, "candidate")

    assert {:ok, ^receipt} =
             Coordinator.submit_candidate(c.conn, c.key, FixtureHost, delivery.lease, "candidate")

    assert {:ok, %{bytes: "candidate"}} = Coordinator.candidate(c.conn, c.key, FixtureHost)

    assert {:error, :candidate_custody_refused} =
             Coordinator.submit_candidate(c.conn, c.key, FixtureHost, delivery.lease, "different")

    wrong = put_in(c.plan, [:execution, :ticket, "tenant_id"], "other")
    assert {:error, :candidate_custody_not_found} = Postgres.candidate(c.conn, wrong)
  end

  test "read tool binds the authenticated instance and rechecks independent grants", c do
    {:ok, delivery} = Coordinator.deliver(c.conn, c.key, FixtureHost, "worker")

    identity = %{
      effect_id: c.plan.effect_id,
      epoch: delivery.lease.epoch,
      backend_ref: delivery.backend_ref,
      principal_id: "agent"
    }

    request = %{name: "task.read", arguments: %{}}
    Process.put(:authenticated_identity, identity)

    assert {:error, :unauthenticated_execution} =
             ToolProxy.request(c.conn, FixtureHost, :forged, request)

    assert {:ok, _} = ToolProxy.request(c.conn, FixtureHost, :fixture_credential, request)

    assert {:ok, %{title: "Scoped input"} = view} =
             ToolProxy.call(c.conn, FixtureHost, identity, request)

    refute Map.has_key?(view, :credentials)
    refute Map.has_key?(view, :evidence)

    assert {:error, :stale_execution_identity} =
             ToolProxy.call(c.conn, FixtureHost, %{identity | epoch: 0}, request)

    assert {:error, :task_access_principal_mismatch} =
             ToolProxy.call(c.conn, FixtureHost, %{identity | principal_id: "forged"}, request)

    revoke_read()
    assert {:error, :task_access_revoked} = ToolProxy.call(c.conn, FixtureHost, identity, request)

    assert {:error, :task_access_revoked} =
             Coordinator.submit_candidate(c.conn, c.key, FixtureHost, delivery.lease, "denied")

    assert {:error, :task_access_revoked} =
             Coordinator.renew(c.conn, c.key, FixtureHost, delivery.lease)

    assert {:error, :task_access_revoked} = Coordinator.candidate(c.conn, c.key, FixtureHost)
    assert {:error, :candidate_custody_not_found} = Postgres.candidate(c.conn, c.plan)
  end

  test "unknown outcome stays held and cancellation needs verified termination, not an ack", c do
    {:ok, delivery} = Coordinator.deliver(c.conn, c.key, FixtureHost, "worker")
    expire(c.conn, c.plan.effect_id)

    assert {:error, :unverified_backend_outcome} =
             Coordinator.recover(c.conn, c.key, FixtureHost, "recovery")

    assert {:ok, %{disposition: :already_dispatched}} =
             Coordinator.deliver(c.conn, c.key, FixtureHost, "other")

    assert Process.get(:launches) == 1
    revoke_read()
    assert {:ok, :cancel_requested} = Coordinator.withdraw(c.conn, c.key, FixtureHost)
    assert {:ok, %{phase: "cancel_requested"}} = Postgres.snapshot(c.conn, c.plan.effect_id)

    Process.put(:observation, %{
      state: :candidate,
      candidate_bytes: "late",
      backend_ref: delivery.backend_ref,
      trusted_fixture: true,
      on_time: true
    })

    assert {:ok, :cancel_requested} = Coordinator.recover(c.conn, c.key, FixtureHost, "recovery")

    Process.put(:observation, %{
      state: :cancelled,
      backend_ref: delivery.backend_ref,
      trusted_fixture: true
    })

    assert {:ok, %{phase: "cancelled"}} =
             Coordinator.recover(c.conn, c.key, FixtureHost, "recovery")

    assert {:error, :candidate_custody_not_found} = Postgres.candidate(c.conn, c.plan)
  end

  test "a lost on-time candidate is recovered only after proof verification", c do
    {:ok, delivery} = Coordinator.deliver(c.conn, c.key, FixtureHost, "worker")
    expire(c.conn, c.plan.effect_id)

    raw = %{
      state: :candidate,
      backend_ref: delivery.backend_ref,
      candidate_bytes: "recovered",
      trusted_fixture: true,
      on_time: false
    }

    Process.put(:observation, raw)

    assert {:error, :unverified_backend_outcome} =
             Coordinator.recover(c.conn, c.key, FixtureHost, "recovery")

    Process.put(:observation, %{raw | on_time: true})

    assert {:ok, %{phase: "candidate_ready"}} =
             Coordinator.recover(c.conn, c.key, FixtureHost, "recovery")

    assert {:ok, %{bytes: "recovered"}} = Postgres.candidate(c.conn, c.plan)
    assert Process.get(:launches) == 1
  end

  test "task changes during execution refuse results and fence the running instance", c do
    {:ok, delivery} = Coordinator.deliver(c.conn, c.key, FixtureHost, "worker")
    context = Process.get(:context)
    task_key = {"chapter", "tenant", "project", "task"}
    Process.put(:context, put_in(context, [:state, :tasks, task_key, :version], 4))

    assert {:error, :stale_agent_run_task} =
             Coordinator.submit_candidate(c.conn, c.key, FixtureHost, delivery.lease, "stale")

    assert {:ok, :cancel_requested} = Coordinator.withdraw(c.conn, c.key, FixtureHost)
    assert {:error, :candidate_custody_not_found} = Postgres.candidate(c.conn, c.plan)
  end

  test "a mismatched tenant key cannot cancel another scope's operational effect", c do
    {:ok, _} = Coordinator.deliver(c.conn, c.key, FixtureHost, "worker")
    context = Process.get(:context)
    other_key = {"chapter", "other-tenant", "project", elem(c.key, 3)}
    run = context.state.agent_runs[c.key]
    Process.put(:context, put_in(context, [:state, :agent_runs, other_key], run))
    assert {:error, :effect_scope_mismatch} = Coordinator.withdraw(c.conn, other_key, FixtureHost)

    assert {:error, :effect_scope_mismatch} =
             Coordinator.recover(c.conn, other_key, FixtureHost, "worker")

    assert {:ok, %{phase: "leased"}} = Postgres.snapshot(c.conn, c.plan.effect_id)
  end
end
