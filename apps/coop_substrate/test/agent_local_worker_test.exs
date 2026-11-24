defmodule CoopSubstrate.AgentLocalWorkerTest do
  @moduledoc """
  Signed admission and withdrawal connected to actual fixed Linux workers.

  This staging experiment deliberately has no ExecutionPort adapter. The host
  orders signed withdrawal, SQL cancellation, and the provider fence explicitly;
  no distributed transaction or automatic cancellation subscription is claimed.
  """
  use CoopSubstrate.LogCase, async: false

  alias AgentCore.Preflight
  alias AgentOpsStore.Postgres
  alias CoopSubstrate.{AgentBackendRequest, AgentLocalWorker, AgentStagingFixture}
  alias CoopSubstrate.{AgentStagingSQL, Canonical, Log}
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias TaskCore.AgentRuns

  @key {"chapter-genesis", "tenant-1", "project-1", "run-1"}
  @context %{environment: :staging}
  @binding ~w(effect_id backend_id admission_id plan_digest execution_deadline worker_identity result_digest)

  defmodule NoBackend do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort

    def launch(_, _, _), do: raise("fixed worker test must use its explicit local provider")
    def poll(_), do: raise("fixed worker test must not use a general execution adapter")
    def cancel(_, _), do: raise("provider termination is not a RecoveryPort assertion")
    def lookup(_, _), do: raise("provider recovery must retain its narrower evidence contract")
  end

  setup do
    AgentStagingSQL.setup!()
    fixture = AgentStagingFixture.prepare()
    features = ~w(text idempotent_launch_v1 effect_lookup_v1 cancellation_v1 bounded_results_v1)

    manifest = %{
      "id" => "approved-profile",
      "version" => 1,
      "adapter_module" => Atom.to_string(NoBackend),
      "parameters" => %{
        "capabilities" => %{
          "features" => features,
          "data_classes" => ["internal"],
          "regions" => ["local"],
          "max_duration_ms" => 300_000,
          "max_output_bytes" => 4096
        }
      }
    }

    profile = %{id: "approved-profile", approved: true, adapter: NoBackend, manifest: manifest}
    read = AgentStagingFixture.access_grant(fixture, "read")
    execute = AgentStagingFixture.access_grant(fixture, "execute")

    intent =
      AgentStagingFixture.request(fixture, %{
        "execution_profile_digest" => {:bytes, Canonical.hash!(manifest)},
        "max_duration_ms" => 300_000
      })

    assert {:ok, _} = Log.append([read, execute, intent])
    grants = %{read: read.event_id, execute: execute.event_id}
    registry = %{"approved-profile" => profile}

    requirements = %{
      "features" => features,
      "data_classes" => ["internal"],
      "region" => "local",
      "max_duration_ms" => 300_000,
      "max_output_bytes" => 4096
    }

    assert {:ok, state} = Log.replay(Projection)
    assert {:ok, run} = AgentRuns.authorized?(state, @key, grants)
    assert {:ok, plan} = Preflight.prepare(run, registry, &Canonical.hash!/1, requirements)
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    conn =
      start_supervised!(
        {Postgrex, Keyword.take(config, [:hostname, :port, :username, :password, :database])}
      )

    assert {:ok, :new} = Postgres.register(conn, plan)
    assert {:ok, row} = Postgres.snapshot(conn, plan.effect_id)

    assert {:ok, lease} =
             Postgres.claim(conn, plan.effect_id, row.version, "local-worker-test", 300_000, 2)

    request = %{
      run_key: @key,
      grants: grants,
      registry: registry,
      requirements: requirements,
      plan: plan,
      lease: lease
    }

    assert {:ok, admission} = Log.admit_agent_launch(@context, request)
    store = AgentLocalWorker.new_store(plan.effect_id)
    assert {:ok, bound} = AgentBackendRequest.create(plan, admission, store.store_id)
    create = Map.put(bound, "schema", "bizkit.agent-local-worker-request.v1")

    %{
      conn: conn,
      fixture: fixture,
      request: request,
      effect: plan.effect_id,
      admission: admission,
      store: store,
      create: create,
      head: Log.head(),
      intent_id: intent.event_id
    }
  end

  for kind <- [:operator, :task_version, :profile_digest] do
    @kind kind
    test "#{kind} withdrawal and fence prevent a delayed actual worker create", c do
      pending = AgentLocalWorker.hold(c.store, c.create)
      change = withdraw(c, @kind)
      cancellation = cancel(c)
      fenced = command(c, "fence")
      assert fenced.response["future_creates_refused"]
      assert fenced.response["execution_started"] == false
      assert is_nil(fenced.response["worker_identity"])
      refute fenced.response["termination_verified"]

      delayed = AgentLocalWorker.release(pending)
      assert delayed.status == 1
      assert delayed.response["error"] == "effect_fenced"
      observed = command(c, "lookup")
      assert observed.response["future_creates_refused"]
      assert observed.response["work_count"] == 0
      assert is_nil(observed.response["worker_identity"])
      refute observed.response["termination_verified"]

      assert Enum.uniq([pending.manager_pid, fenced.manager_pid, observed.manager_pid])
             |> length() == 3

      evidence(c, "#{@kind}-before-create", %{
        "change" => change,
        "cancellation" => cancellation,
        "fence_acknowledgement" => fenced.response,
        "delayed_create_refusal" => delayed.response,
        "fresh_lookup" => observed.response,
        "create_released_after_fence_acknowledgement" => true,
        "manager_pids" => [pending.manager_pid, fenced.manager_pid, observed.manager_pid]
      })
    end

    @kind kind
    test "#{kind} withdrawal fences and terminates an actual running fixed worker", c do
      started = create(c)
      change = withdraw(c, @kind)
      cancellation = cancel(c)
      fenced = command(c, "fence")
      assert fenced.response["future_creates_refused"]
      assert Map.take(fenced.response, @binding) == Map.take(started.response, @binding)
      refute fenced.response["termination_verified"]
      assert fenced.kernel_observation["live"]

      stopped = command(c, "terminate")
      assert stopped.response["termination_verified"]
      assert stopped.response["future_creates_refused"]
      assert stopped.kernel_exit_observed
      assert Map.take(stopped.response, @binding) == Map.take(started.response, @binding)

      delayed = AgentLocalWorker.request(c.store, c.create)
      assert delayed.status == 1
      assert delayed.response["error"] == "effect_fenced"
      observed = command(c, "lookup")
      assert observed.response["termination_verified"]
      assert observed.response["work_count"] == 1
      assert Map.take(observed.response, @binding) == Map.take(started.response, @binding)

      evidence(c, "#{@kind}-after-work", %{
        "change" => change,
        "cancellation" => cancellation,
        "started" => started.response,
        "live_worker_observation" => started.kernel_observation,
        "fence_acknowledgement" => fenced.response,
        "termination" => stopped.response,
        "independent_pidfd_exit_observed" => stopped.kernel_exit_observed,
        "delayed_create_refusal" => delayed.response,
        "fresh_lookup" => observed.response,
        "manager_pids" => [
          started.manager_pid,
          fenced.manager_pid,
          stopped.manager_pid,
          observed.manager_pid
        ]
      })
    end
  end

  test "actual work survives a killed manager with no creation reply and is not respawned", c do
    crashed = AgentLocalWorker.crash_after_work(c.store, c.create)
    assert crashed.status == -9
    assert crashed.stdout == ""
    assert crashed.kernel_observation["live"]
    assert crashed.observed_before_crash["execution_started"]
    assert crashed.observed_before_crash["work_count"] == 1

    retried = create(c)

    assert Map.take(retried.response, @binding) ==
             Map.take(crashed.observed_before_crash, @binding)

    assert retried.response["work_count"] == 1
    assert retried.manager_pid != crashed.manager_pid
    change = withdraw(c, :operator)
    cancellation = cancel(c)
    stopped = command(c, "terminate")
    assert stopped.response["termination_verified"]
    assert stopped.kernel_exit_observed
    observed = command(c, "lookup")
    assert observed.response["termination_verified"]
    assert Map.take(observed.response, @binding) == Map.take(retried.response, @binding)

    evidence(c, "lost-create-reply", %{
      "manager_sigkill_status" => crashed.status,
      "ordinary_reply_bytes" => byte_size(crashed.stdout),
      "before_manager_kill" => crashed.observed_before_crash,
      "live_worker_after_manager_kill" => crashed.kernel_observation,
      "retried_create" => retried.response,
      "change" => change,
      "cancellation" => cancellation,
      "termination" => stopped.response,
      "independent_pidfd_exit_observed" => stopped.kernel_exit_observed,
      "fresh_lookup" => observed.response,
      "manager_pids" => [
        crashed.manager_pid,
        retried.manager_pid,
        stopped.manager_pid,
        observed.manager_pid
      ]
    })
  end

  defp create(c) do
    result = AgentLocalWorker.request(c.store, c.create)
    assert result.status == 0, provider_diagnostic(result)
    assert result.response["schema"] == "bizkit.agent-local-worker-receipt.v1"
    assert result.response["execution_started"]
    assert result.response["work_count"] == 1
    assert result.kernel_observation["live"]
    refute result.response["termination_verified"]
    refute result.response["ambiguity"]
    assert is_binary(result.response["result_digest"])

    for field <- ~w(effect_id admission_id plan_digest execution_deadline) do
      assert result.response[field] == c.create[field]
    end

    result
  end

  defp command(c, operation) do
    result =
      AgentLocalWorker.request(c.store, AgentLocalWorker.command(c.store, c.effect, operation))

    assert result.status == 0, provider_diagnostic(result)
    assert result.response["schema"] == "bizkit.agent-local-worker-receipt.v1"
    assert result.response["operation"] == operation
    assert result.response["store_id"] == c.store.store_id
    assert result.response["effect_id"] == c.effect
    result
  end

  defp provider_diagnostic(result) do
    error = if is_map(result.response), do: result.response["error"], else: :invalid_response

    "local worker provider error=#{inspect(error, limit: 5, printable_limit: 128)}; " <>
      "stderr=#{inspect(result.stderr, limit: 5, printable_limit: 512)}"
  end

  defp cancel(c) do
    assert {:ok, _} = Postgres.request_cancel(c.conn, c.effect, c.admission.version)

    assert {:ok, %{phase: "cancel_requested", backend_ref: nil, attempts: 1} = row} =
             Postgres.snapshot(c.conn, c.effect)

    Map.take(row, [:phase, :version, :epoch, :attempts, :backend_ref])
  end

  defp withdraw(c, :operator) do
    event =
      signed_event(c.fixture.gov, "TaskOperatorRevokedV1", %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "authorization_event_id" => c.fixture.grant.event_id
      })

    assert {:ok, _} = Log.append(event)
    assert {:error, :agent_run_operator_revoked} = Log.admit_agent_launch(@context, c.request)
    signed_change(event)
  end

  defp withdraw(c, :task_version) do
    event =
      signed_event(c.fixture.op, "TaskStartedV1", %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "task_id" => "task-1",
        "principal_id" => "operator-1",
        "authorization_event_id" => c.fixture.grant.event_id,
        "lifecycle_version" => 1,
        "expected_version" => 7
      })

    assert {:ok, _} = Log.append(event)
    assert {:error, :stale_agent_run_task} = Log.admit_agent_launch(@context, c.request)
    signed_change(event)
  end

  defp withdraw(c, :profile_digest) do
    changed =
      update_in(c.request, [:registry, "approved-profile", :manifest, "parameters"], fn params ->
        Map.put(params, "policy_revision", 2)
      end)

    assert {:error, :execution_profile_digest_mismatch} =
             Log.admit_agent_launch(@context, changed)

    assert Log.head() == c.head
    %{"origin" => "unsigned_supplied_host_profile", "source_head_unchanged" => true}
  end

  defp signed_change(event) do
    %{
      "origin" => "signed_ledger_event",
      "event_id" => event.event_id,
      "source_seq" => Log.head().global_seq,
      "source_hash" => hex(Log.head().global_hash)
    }
  end

  defp evidence(c, name, fields) do
    assert :ok = Log.verify_chains()

    AgentLocalWorker.evidence(
      name,
      c.effect,
      c.store.store_id,
      Map.merge(fields, %{
        "signed_intent_event_id" => c.intent_id,
        "admission_id" => c.admission.admission_id,
        "plan_digest" => hex(c.admission.plan_digest),
        "admission_source_seq" => c.admission.source_seq,
        "admission_source_hash" => hex(c.admission.source_hash),
        "signed_chains_verified" => true,
        "guarantee_begins_at_provider_fence_acknowledgement" => true,
        "scope" => "fixed_local_non_forking_worker"
      })
    )
  end

  defp hex(value), do: Base.encode16(value, case: :lower)
end
