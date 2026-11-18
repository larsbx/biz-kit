defmodule CoopSubstrate.AgentBackendReceiverTest do
  @moduledoc """
  Real signed admission connected to an independent SQLite receiver process.

  A backend fence orders future creates only after its own acknowledgement.
  Signed withdrawal and host profile changes are not atomically observed by
  this receiver. No test starts a worker or obtains verified termination.
  """
  use CoopSubstrate.LogCase, async: false

  alias AgentCore.Preflight
  alias AgentOpsStore.Postgres
  alias CoopSubstrate.{AgentBackendReceiver, AgentBackendRequest, AgentStagingFixture}
  alias CoopSubstrate.{AgentStagingSQL, Canonical, Log}
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias TaskCore.AgentRuns

  @key {"chapter-genesis", "tenant-1", "project-1", "run-1"}
  @context %{environment: :staging}
  @binding ~w(effect_id backend_id admission_id plan_digest execution_deadline)

  defmodule NoBackend do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort

    def launch(_, _, _), do: raise("receiver acceptance must not launch execution")
    def poll(_), do: raise("receiver acceptance must not poll execution")
    def cancel(_, _), do: raise("receiver fence must not claim execution cancellation")
    def lookup(_, _), do: raise("receiver lookup must not claim execution recovery")
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
             Postgres.claim(conn, plan.effect_id, row.version, "receiver-test", 300_000, 2)

    request = %{
      run_key: @key,
      grants: grants,
      registry: registry,
      requirements: requirements,
      plan: plan,
      lease: lease
    }

    assert {:ok, admission} = Log.admit_agent_launch(@context, request)
    store = AgentBackendReceiver.new_store()
    assert {:ok, create} = AgentBackendRequest.create(plan, admission, store.store_id)

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
    test "#{kind} change followed by an acknowledged fence refuses an already-started create process",
         c do
      pending = AgentBackendReceiver.hold(c.store, c.create)
      change = withdraw(c, @kind)
      cancellation = cancel(c)
      {fence, fenced} = fence(c)
      assert fenced.response["state"] == "fenced"
      assert is_nil(fenced.response["backend_id"])
      assert is_nil(fenced.response["admission_id"])

      delayed = AgentBackendReceiver.release(pending)
      assert delayed.status == 1

      assert {:error, :agent_backend_effect_fenced} =
               AgentBackendRequest.verify_response(c.create, delayed.response)

      observed = lookup(c)
      assert observed.response["state"] == "fenced"
      assert observed.response["future_creates_refused"]
      assert is_nil(observed.response["backend_id"])
      refute observed.response["execution_started"]
      refute observed.response["termination_verified"]

      assert Enum.uniq([pending.receiver_pid, fenced.receiver_pid, observed.receiver_pid])
             |> length() == 3

      assert :ok = Log.verify_chains()

      assert {:ok, %{phase: "cancel_requested", backend_ref: nil}} =
               Postgres.snapshot(c.conn, c.effect)

      evidence(c, Atom.to_string(@kind), %{
        "change" => change,
        "cancellation" => cancellation,
        "fence_request" => fence,
        "fence_acknowledgement" => fenced.response,
        "delayed_create_refusal" => delayed.response,
        "fresh_lookup" => observed.response,
        "receiver_pids" => [pending.receiver_pid, fenced.receiver_pid, observed.receiver_pid],
        "create_payload_released_after_fence_acknowledgement" => true
      })
    end
  end

  test "an accepted identity survives signed withdrawal and a permanent backend fence", c do
    accepted = create(c)
    change = withdraw(c, :operator)
    cancellation = cancel(c)
    {_request, fenced} = fence(c)
    assert Map.take(fenced.response, @binding) == Map.take(accepted.response, @binding)
    assert fenced.response["state"] == "fenced"
    assert fenced.response["future_creates_refused"]
    refute fenced.response["execution_started"]
    refute fenced.response["termination_verified"]

    delayed = AgentBackendReceiver.request(c.store, c.create)
    assert delayed.status == 1

    assert {:error, :agent_backend_effect_fenced} =
             AgentBackendRequest.verify_response(c.create, delayed.response)

    observed = lookup(c)
    assert Map.take(observed.response, @binding) == Map.take(accepted.response, @binding)
    assert observed.response["state"] == "fenced"
    assert observed.receiver_pid != accepted.receiver_pid

    evidence(c, "accepted-then-fenced", %{
      "change" => change,
      "cancellation" => cancellation,
      "accepted" => accepted.response,
      "fence_acknowledgement" => fenced.response,
      "fresh_lookup" => observed.response,
      "receiver_pids" => [accepted.receiver_pid, fenced.receiver_pid, observed.receiver_pid]
    })
  end

  test "SIGKILL after committed acceptance but before its reply preserves the original signed binding",
       c do
    crashed = AgentBackendReceiver.crash_after_commit(c.store, c.create)
    assert crashed.committed
    assert crashed.status == -9
    assert crashed.stdout == ""
    assert crashed.response == nil
    assert crashed.stderr == "COMMITTED\n"
    assert crashed.allocation_count == 1
    assert crashed.stored_binding["state"] == "accepted"
    assert_original_binding(c, crashed.stored_binding)

    recovered = create(c, "existing")
    observed = lookup(c)
    repeated = create(c, "existing")

    for result <- [recovered, observed, repeated] do
      assert result.response["state"] == "accepted"
      assert Map.take(result.response, @binding) == Map.take(crashed.stored_binding, @binding)
      assert_original_binding(c, result.response)
    end

    assert Enum.uniq([crashed.receiver_pid, recovered.receiver_pid, observed.receiver_pid])
           |> length() == 3

    assert Log.head() == c.head

    assert {:ok, %{phase: "leased", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(c.conn, c.effect)

    evidence(c, "committed-response-loss", %{
      "committed_before_sigkill" => true,
      "crashed_exit_status" => crashed.status,
      "reply_bytes_before_sigkill" => byte_size(crashed.stdout),
      "allocation_count_before_sigkill" => crashed.allocation_count,
      "binding_observed_before_sigkill" => crashed.stored_binding,
      "recovered" => recovered.response,
      "fresh_lookup" => observed.response,
      "receiver_pids" => [crashed.receiver_pid, recovered.receiver_pid, observed.receiver_pid]
    })
  end

  test "a deleted or replaced backend store cannot silently forget a pinned identity", c do
    accepted = create(c)
    File.rename!(c.store.db, c.store.db <> ".retained")
    assert {:ok, lookup_request} = AgentBackendRequest.lookup(c.effect, c.store.store_id)
    missing = AgentBackendReceiver.request(c.store, lookup_request)
    assert missing.status == 2

    assert {:error, :agent_backend_store_missing} =
             AgentBackendRequest.verify_response(lookup_request, missing.response)

    refute File.exists?(c.store.db)
    replacement = AgentBackendReceiver.initialize(c.store)
    refute replacement.store_id == c.store.store_id
    assert {:ok, fence_request} = AgentBackendRequest.fence(c.effect, c.store.store_id)

    for request <- [c.create, lookup_request, fence_request] do
      result = AgentBackendReceiver.request(replacement, request)
      assert result.status == 2

      assert {:error, :agent_backend_store_identity_mismatch} =
               AgentBackendRequest.verify_response(request, result.response)
    end

    observed = lookup(%{c | store: replacement})
    assert observed.response["state"] == "unknown"
    assert is_nil(observed.response["backend_id"])
    refute observed.response["future_creates_refused"]

    evidence(c, "store-replacement", %{
      "accepted" => accepted.response,
      "missing_store_refusal" => missing.response,
      "replacement_store_id" => replacement.store_id,
      "replacement_lookup" => observed.response,
      "old_pinned_create_lookup_fence_refused" => true
    })
  end

  test "the backend cannot rebind an admitted effect to a different valid plan digest", c do
    accepted = create(c)
    changed = Map.put(c.create, "plan_digest", String.duplicate("0", 64))
    refute changed["plan_digest"] == c.create["plan_digest"]
    conflict = AgentBackendReceiver.request(c.store, changed)
    assert conflict.status == 1

    assert {:error, :agent_backend_binding_conflict} =
             AgentBackendRequest.verify_response(changed, conflict.response)

    observed = lookup(c)
    assert Map.take(observed.response, @binding) == Map.take(accepted.response, @binding)
    assert_original_binding(c, observed.response)

    evidence(c, "immutable-binding", %{
      "accepted" => accepted.response,
      "conflicting_binding_refusal" => conflict.response,
      "fresh_lookup" => observed.response
    })
  end

  defp create(c, disposition \\ "created") do
    result = AgentBackendReceiver.request(c.store, c.create)
    assert result.status == 0
    assert {:ok, response} = AgentBackendRequest.verify_response(c.create, result.response)
    assert response["disposition"] == disposition
    assert response["state"] == "accepted"
    refute response["execution_started"]
    refute response["termination_verified"]
    assert_original_binding(c, response)
    result
  end

  defp fence(c) do
    assert {:ok, request} = AgentBackendRequest.fence(c.effect, c.store.store_id)
    result = AgentBackendReceiver.request(c.store, request)
    assert result.status == 0
    assert {:ok, response} = AgentBackendRequest.verify_response(request, result.response)
    assert response["state"] == "fenced" and response["future_creates_refused"]
    refute response["execution_started"]
    refute response["termination_verified"]
    {request, result}
  end

  defp lookup(c) do
    assert {:ok, request} = AgentBackendRequest.lookup(c.effect, c.store.store_id)
    result = AgentBackendReceiver.request(c.store, request)
    assert result.status == 0
    assert {:ok, _} = AgentBackendRequest.verify_response(request, result.response)
    result
  end

  defp assert_original_binding(c, response) do
    for field <- ~w(effect_id admission_id plan_digest execution_deadline) do
      assert response[field] == c.create[field]
    end

    assert is_binary(response["backend_id"])
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

    AgentBackendReceiver.evidence(
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
        "guarantee_begins_at_backend_fence_acknowledgement" => true
      })
    )
  end

  defp hex(value), do: Base.encode16(value, case: :lower)
end
