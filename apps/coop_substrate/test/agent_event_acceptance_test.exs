defmodule CoopSubstrate.AgentEventAcceptanceTest do
  @moduledoc "Real signed ledger + PostgreSQL staging acceptance; synthetic backend only."
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
          "UPDATE agent_ops.execution_attempts SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE phase='leased'",
          []
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
               prepares: 0,
               expire_claim: false,
               conn: nil
             }
           end,
           [name: @fixture]
         ]}
    })

    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    conn =
      start_supervised!(
        {Postgrex, Keyword.take(config, [:hostname, :port, :username, :password, :database])}
      )

    Agent.update(@fixture, &%{&1 | conn: conn})

    request =
      AgentStagingFixture.request(ctx, %{
        "execution_profile_digest" => {:bytes, Canonical.hash!(manifest)}
      })

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
end
