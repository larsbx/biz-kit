defmodule CoopSubstrate.AgentEventAcceptanceTest do
  @moduledoc """
  Real signed ledger + PostgreSQL staging acceptance; synthetic backend only.

  Signed authority is reconstructed from Log, never from a process dictionary.
  The adapter, registry and observation issuer remain trusted test fixtures.
  Worker/Log and SQL-session recovery does not establish backend durability,
  database power-loss recovery, or atomic external launch/revocation fencing.
  """
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{AgentStagingFixture, AgentStagingSQL, Canonical, Log}
  alias AgentOpsStore.{Coordinator, EventWakeup, Postgres}
  alias TaskCore.ExecutionWorker
  @key {"chapter-genesis", "tenant-1", "project-1", "run-1"}
  @fixture __MODULE__.Fixture

  defmodule Adapter do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort
    def launch(_execution, _profile, effect) do
      config = Agent.get(CoopSubstrate.AgentEventAcceptanceTest.Fixture, & &1)
      # Synthetic external backend keeps its identity across worker restarts.
      Agent.update(CoopSubstrate.AgentEventAcceptanceTest.Fixture, fn s ->
        %{s | launches: [effect | s.launches], backend: "backend-1"}
      end)

      send(config.parent, {:launched, effect, self()})

      if config.block_launch,
        do:
          (receive do
             :release -> :ok
           end)

      {:ok, "backend-1"}
    end

    def lookup(_, _) do
      {:ok, Agent.get(CoopSubstrate.AgentEventAcceptanceTest.Fixture, & &1.backend)}
    end

    def poll(_), do: {:ok, %{state: :running}}
    def cancel(_, _), do: :ok
  end

  defmodule Host do
    @behaviour AgentOpsStore.Host
    def environment, do: :staging
    def committed_state, do: Log.replay(CoopSubstrate.Projections.Tasks)

    def context(_) do
      before =
        Agent.get_and_update(CoopSubstrate.AgentEventAcceptanceTest.Fixture, fn s ->
          {s, %{s | context_reads: s.context_reads + 1}}
        end)

      if before.block_recheck and before.context_reads == 1 do
        send(before.parent, {:before_recheck, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "signed authority recheck barrier timed out"
        end
      end

      cfg = Agent.get(CoopSubstrate.AgentEventAcceptanceTest.Fixture, & &1)
      with {:ok, state} <- committed_state(), do: {:ok, Map.put(cfg.context, :state, state)}
    end

    def consent(_) do
      cfg =
        Agent.get_and_update(CoopSubstrate.AgentEventAcceptanceTest.Fixture, fn s ->
          {s, %{s | prepares: s.prepares + 1}}
        end)

      if cfg.block_claim and cfg.prepares == 1 do
        send(cfg.parent, {:after_claim, self()})

        receive do
          :release -> :ok
        end
      end

      if cfg.expire_claim and cfg.prepares == 1 do
        Postgrex.query!(
          cfg.conn,
          "UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE effect_id=$1 AND phase='leased'",
          [cfg.effect]
        )
      end

      :ok
    end

    def reference(_, handle), do: {:ok, handle}

    def recovery_context(_) do
      cfg = Agent.get(CoopSubstrate.AgentEventAcceptanceTest.Fixture, & &1)
      {:ok, %{registry: cfg.context.registry, hash_manifest: &Canonical.hash!/1}}
    end

    def verify_observation(row, "backend-1") do
      # Test-only receipt issuer. Does not establish real backend conformance.
      {:ok,
       %{
         state: :running,
         verified: true,
         final: true,
         effect_id: row.effect_id,
         epoch: row.epoch,
         backend_ref: "backend-1",
         receipt: "synthetic-recovery-receipt"
       }}
    end

    def verify_observation(_, _), do: {:error, :unverified_backend_outcome}

    def request_termination(effect, ref) do
      parent = Agent.get(CoopSubstrate.AgentEventAcceptanceTest.Fixture, & &1.parent)
      send(parent, {:termination_requested, effect, ref})
      :ok
    end

    def authenticate_execution(_), do: {:error, :fixture_has_no_runtime_credentials}
  end

  setup do
    AgentStagingSQL.setup!()
    ctx = AgentStagingFixture.prepare()
    features = ~w(text idempotent_launch_v1 effect_lookup_v1 cancellation_v1 bounded_results_v1)

    manifest = %{
      "id" => "approved-profile",
      "version" => 1,
      "adapter_module" => Atom.to_string(Adapter),
      "parameters" => %{
        "capabilities" => %{
          "features" => features,
          "data_classes" => ["internal"],
          "regions" => ["local"],
          "max_duration_ms" => 30_000,
          "max_output_bytes" => 4096
        }
      }
    }

    profile = %{id: "approved-profile", approved: true, adapter: Adapter, manifest: manifest}
    read = AgentStagingFixture.access_grant(ctx, "read")
    execute = AgentStagingFixture.access_grant(ctx, "execute")
    {:ok, _} = Log.append([read, execute])

    context = %{
      grants: %{read: read.event_id, execute: execute.event_id},
      registry: %{"approved-profile" => profile},
      hash_manifest: &Canonical.hash!/1,
      requirements: %{
        "features" => features,
        "data_classes" => ["internal"],
        "region" => "local",
        "max_duration_ms" => 30_000,
        "max_output_bytes" => 4096
      }
    }

    parent = self()

    start_supervised!(%{
      id: @fixture,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               context: context,
               parent: parent,
               launches: [],
               backend: nil,
               block_launch: false,
               block_claim: false,
               block_recheck: false,
               context_reads: 0,
               prepares: 0,
               expire_claim: false,
               conn: nil,
               effect: nil
             }
           end,
           [name: @fixture]
         ]}
    })

    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    conn =
      start_supervised!(
        Supervisor.child_spec(
          {Postgrex, Keyword.take(config, [:hostname, :port, :username, :password, :database])},
          id: :signed_launch_connection
        )
      )

    request =
      AgentStagingFixture.request(ctx, %{
        "execution_profile_digest" => {:bytes, Canonical.hash!(manifest)}
      })

    Agent.update(@fixture, &%{&1 | conn: conn, effect: "agent-run:" <> request.event_id})

    %{
      conn: conn,
      request: request,
      ctx: ctx,
      execute: execute,
      effect: "agent-run:" <> request.event_id
    }
  end

  defp worker(conn, extra \\ []) do
    parent = self()

    start_supervised!(
      {ExecutionWorker,
       Keyword.merge(
         [
           interval_ms: 60_000,
           timeout_ms: 60_000,
           tick: fn ->
             result = Coordinator.tick(conn, Host, "signed-fixture-worker")
             send(parent, {:tick_done, result})
             result
           end
         ],
         extra
       )}
    )
  end

  test "forged hints cannot admit a run; committed replay launches once despite duplicate hints",
       ctx do
    worker = worker(ctx.conn)
    notifier = start_supervised!({EventWakeup, host: Host, target: worker, cooldown_ms: 10})
    assert_receive {:tick_done, {:ok, []}}, 2000
    for _ <- 1..100, do: send(notifier, {:coop_ledger, [ctx.request]})
    assert_receive {:tick_done, {:ok, []}}, 2000
    refute_receive {:launched, _, _}, 30
    forged = %{ctx.request | sigs: %{ctx.ctx.op.signer.key_id => <<0::512>>}}
    assert {:error, _} = Log.append(forged)
    assert {:ok, _} = Log.append(ctx.request)
    assert_receive {:launched, effect, _}, 2000
    assert effect == ctx.effect
    assert_receive {:tick_done, _}, 2000
    for _ <- 1..100, do: send(notifier, {:coop_ledger, [%{global_seq: 999_999}]})
    assert_receive {:tick_done, _}, 2000
    assert Agent.get(@fixture, & &1.launches) == [ctx.effect]
    assert {:ok, %{epoch: 1, phase: "leased"}} = Postgres.snapshot(ctx.conn, ctx.effect)
    assert :ok = Log.verify_chains()
  end

  test "lost notifications recover through the retained periodic tick after log restart", ctx do
    # No notifier exists at append: the signal is irretrievably lost.
    worker = worker(ctx.conn)
    assert_receive {:tick_done, {:ok, []}}, 2000
    assert {:ok, _} = Log.append(ctx.request)
    restart_log()
    # Inject the periodic timer message deterministically; no wakeup payload is used.
    send(worker, :tick)
    assert_receive {:launched, _, _}, 2000
    assert_receive {:tick_done, _}, 2000
    assert Agent.get(@fixture, & &1.launches) == [ctx.effect]
  end

  test "two independent connections racing signed delivery produce one backend launch", ctx do
    assert {:ok, _} = Log.append(ctx.request)

    second =
      start_supervised!(
        Supervisor.child_spec(
          {Postgrex, Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)},
          id: :second_signed_delivery_connection
        )
      )

    first = Task.async(fn -> Coordinator.deliver(ctx.conn, @key, Host, "one") end)
    other = Task.async(fn -> Coordinator.deliver(second, @key, Host, "two") end)
    results = [Task.await(first), Task.await(other)]
    assert Enum.count(results, &match?({:ok, %{disposition: :dispatched}}, &1)) == 1
    assert Agent.get(@fixture, & &1.launches) == [ctx.effect]
    assert {:ok, %{epoch: 1, attempts: 1}} = Postgres.snapshot(ctx.conn, ctx.effect)
  end

  test "signed revocation fences running execution and forged hints cannot relaunch", ctx do
    assert {:ok, _} = Log.append(ctx.request)
    assert {:ok, %{disposition: :dispatched}} = Coordinator.deliver(ctx.conn, @key, Host, "one")

    revoke =
      signed_event(ctx.ctx.gov, "TaskAccessRevokedV1", %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "task_id" => "task-1",
        "grant_event_id" => ctx.execute.event_id
      })

    assert {:ok, _} = Log.append(revoke)
    worker = worker(ctx.conn)
    notifier = start_supervised!({EventWakeup, host: Host, target: worker, cooldown_ms: 10})
    assert_receive {:tick_done, _}, 2000
    assert_receive {:termination_requested, _, "backend-1"}, 2000
    for _ <- 1..30, do: send(notifier, {:coop_ledger, [ctx.request]})
    assert_receive {:tick_done, _}, 2000
    assert {:error, :task_access_revoked} = Coordinator.deliver(ctx.conn, @key, Host, "two")
    assert Agent.get(@fixture, & &1.launches) == [ctx.effect]
    assert {:ok, %{phase: "cancel_requested"}} = Postgres.snapshot(ctx.conn, ctx.effect)
  end

  test "crash after backend launch before handle attachment recovers without another launch",
       ctx do
    assert {:ok, _} = Log.append(ctx.request)
    Agent.update(@fixture, &%{&1 | block_launch: true})
    worker = worker(ctx.conn)
    assert_receive {:launched, _, child}, 2000
    monitor = Process.monitor(child)
    active = :sys.get_state(worker).active
    send(worker, {:tick_timeout, active.job})
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 2000
    assert {:ok, %{backend_ref: nil, phase: "leased"}} = Postgres.snapshot(ctx.conn, ctx.effect)
    stop_supervised!(ExecutionWorker)
    # The worker cannot infer absence. Advance only the test lease clock.
    Postgrex.query!(
      ctx.conn,
      "UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE effect_id=$1",
      [ctx.effect]
    )

    Agent.update(@fixture, &%{&1 | block_launch: false})
    restart_log()
    worker(ctx.conn)
    assert_receive {:tick_done, _}, 2000

    assert {:ok, %{backend_ref: "backend-1", epoch: 2, phase: "leased"}} =
             Postgres.snapshot(ctx.conn, ctx.effect)

    assert Agent.get(@fixture, & &1.launches) == [ctx.effect]
  end

  test "crash after claim cannot be mistaken for proved backend absence", ctx do
    assert {:ok, _} = Log.append(ctx.request)
    Agent.update(@fixture, &%{&1 | block_claim: true})
    worker = worker(ctx.conn)
    assert_receive {:after_claim, child}, 2000
    monitor = Process.monitor(child)
    active = :sys.get_state(worker).active
    send(worker, {:tick_timeout, active.job})
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 2000
    stop_supervised!(ExecutionWorker)

    Postgrex.query!(
      ctx.conn,
      "UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE effect_id=$1",
      [ctx.effect]
    )

    Agent.update(@fixture, &%{&1 | block_claim: false})
    restart_log()
    worker(ctx.conn)
    assert_receive {:tick_done, _}, 2000
    assert Agent.get(@fixture, & &1.launches) == []

    assert {:ok, %{epoch: 1, backend_ref: nil, phase: "leased"}} =
             Postgres.snapshot(ctx.conn, ctx.effect)
  end

  test "lease expiry while checking current signed authority refuses backend launch", ctx do
    assert {:ok, _} = Log.append(ctx.request)
    Agent.update(@fixture, &%{&1 | expire_claim: true})
    assert {:error, :launch_lease_invalid} = Coordinator.deliver(ctx.conn, @key, Host, "one")
    assert Agent.get(@fixture, & &1.launches) == []

    assert {:ok, %{phase: "leased", expired: true, epoch: 1}} =
             Postgres.snapshot(ctx.conn, ctx.effect)
  end

  test "a second SQL connection cancels a claim during authority recheck before launch", ctx do
    assert {:ok, _} = Log.append(ctx.request)
    Agent.update(@fixture, &%{&1 | block_claim: true})
    delivery = Task.async(fn -> Coordinator.deliver(ctx.conn, @key, Host, "one") end)
    assert_receive {:after_claim, paused}, 5_000
    second = connection(:lease_fence_connection)
    assert {:ok, row} = Postgres.snapshot(second, ctx.effect)
    assert row.phase == "leased"
    assert {:ok, _} = Postgres.request_cancel(second, ctx.effect, row.version)
    send(paused, :release)
    assert {:error, :launch_lease_invalid} = Task.await(delivery, 5_000)
    assert Agent.get(@fixture, & &1.launches) == []

    fresh = restart_sessions()

    assert {:ok, %{disposition: :already_dispatched, phase: "cancel_requested"}} =
             Coordinator.deliver(fresh, @key, Host, "fresh-worker")

    assert {:ok, %{phase: "cancel_requested", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(fresh, ctx.effect)

    assert Agent.get(@fixture, & &1.launches) == []
  end

  test "signed operator revocation after claim remains fenced after fresh replay", ctx do
    drift_after_claim(ctx, :agent_run_operator_revoked, fn ->
      revoke =
        signed_event(ctx.ctx.gov, "TaskOperatorRevokedV1", %{
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "authorization_event_id" => ctx.ctx.grant.event_id
        })

      assert {:ok, _} = Log.append(revoke)
    end)
  end

  test "signed task revision after claim remains stale after fresh replay", ctx do
    drift_after_claim(ctx, :stale_agent_run_task, fn ->
      start =
        signed_event(ctx.ctx.op, "TaskStartedV1", %{
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "task_id" => "task-1",
          "principal_id" => "operator-1",
          "authorization_event_id" => ctx.ctx.grant.event_id,
          "lifecycle_version" => 1,
          "expected_version" => 7
        })

      assert {:ok, _} = Log.append(start)
      assert {:ok, state} = Host.committed_state()
      assert state.tasks[{"chapter-genesis", "tenant-1", "project-1", "task-1"}].version == 8
    end)
  end

  test "a changed trusted profile cannot reuse the signed intent digest after fresh replay",
       ctx do
    drift_after_claim(ctx, :execution_profile_digest_mismatch, fn ->
      # Profile approval is trusted host configuration. The run's old digest
      # remains an authentic signed ledger fact; no replacement is admitted.
      Agent.update(@fixture, fn s ->
        update_in(s, [:context, :registry, "approved-profile", :manifest, "parameters"], fn p ->
          Map.put(p, "fixture_revision", 2)
        end)
      end)
    end)
  end

  defp drift_after_claim(ctx, reason, mutate) do
    assert {:ok, _} = Log.append(ctx.request)
    Agent.update(@fixture, &%{&1 | block_recheck: true})
    delivery = Task.async(fn -> Coordinator.deliver(ctx.conn, @key, Host, "one") end)
    assert_receive {:before_recheck, paused}, 5_000
    assert {:ok, %{phase: "leased", attempts: 1}} = Postgres.snapshot(ctx.conn, ctx.effect)
    mutate.()
    assert :ok = Log.verify_chains()
    send(paused, :release)
    assert {:error, :authority_changed_after_claim} = Task.await(delivery, 5_000)
    assert {:error, ^reason} = Coordinator.prepare(@key, Host)
    assert Agent.get(@fixture, & &1.launches) == []

    assert {:ok, %{phase: "cancel_requested", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(ctx.conn, ctx.effect)

    fresh = restart_sessions()
    head = Log.head()

    for _ <- 1..3 do
      assert {:error, ^reason} = Coordinator.deliver(fresh, @key, Host, "fresh-worker")
    end

    assert Log.head() == head
    assert :ok = Log.verify_chains()
    assert Agent.get(@fixture, & &1.launches) == []

    assert {:ok, %{phase: "cancel_requested", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(fresh, ctx.effect)
  end

  defp restart_sessions do
    stop_supervised!(:signed_launch_connection)
    restart_log()
    fresh = connection(:fresh_signed_launch_connection)
    Agent.update(@fixture, &%{&1 | conn: fresh})
    fresh
  end

  defp connection(id) do
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    start_supervised!(
      Supervisor.child_spec(
        {Postgrex, Keyword.take(config, [:hostname, :port, :username, :password, :database])},
        id: id
      )
    )
  end
end
