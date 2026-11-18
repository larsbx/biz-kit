defmodule CoopSubstrate.AgentBackendExecutionTest do
  use CoopSubstrate.LogCase, async: false

  alias AgentOpsStore.{Coordinator, Postgres}
  alias CoopSubstrate.{AgentBackendRequest, AgentStagingFixture, Canonical, Log}
  alias CoopSubstrate.AgentExecutionFixture, as: Backend

  defmodule LegacyPort do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort

    def launch(_, _, _), do: raise("fixture must not use legacy launch")
    def poll(_), do: raise("fixture must use native workload observation")
    def cancel(_, _), do: raise("fixture must use the durable fence")
    def lookup(_, _), do: raise("fixture must use bound lookup")
  end

  defmodule WithdrawalHost do
    @moduledoc false
    alias CoopSubstrate.Projections.Tasks, as: Projection

    def environment, do: :staging

    def context(_key) do
      {c, _, _} = Process.get(__MODULE__)

      with {:ok, state} <- Log.replay(Projection) do
        context = Map.take(c.request, [:grants, :registry, :requirements])
        {:ok, Map.merge(context, %{state: state, hash_manifest: &Canonical.hash!/1})}
      end
    end

    def consent(_), do: :ok

    def request_termination(effect, backend_ref) do
      {%{effect: ^effect} = c, ^backend_ref, fault} = Process.get(__MODULE__)
      result = Backend.fence(c, fault)
      send(self(), {:fixture_fence, result})

      with {:ok, request} <- AgentBackendRequest.fence(effect, c.store.store_id),
           {:ok, %{"state" => "fenced", "backend_id" => ^backend_ref}} <-
             AgentBackendRequest.verify_response(request, result["receipt"]) do
        :ok
      end
    end
  end

  setup_all do
    %{worker: Backend.compile_worker()}
  end

  setup %{worker: worker} do
    c = AgentStagingFixture.admit!(LegacyPort, %{"fixture_worker_sha256" => worker.sha256})
    store = Backend.new_store(worker)
    assert {:ok, create} = AgentBackendRequest.create(c.request.plan, c.admission, store.store_id)
    c = Map.merge(c, %{store: store, create: create})
    on_exit(fn -> Backend.fence(c) end)
    c
  end

  test "concurrent deliveries start one restricted Linux workload for the exact binding", c do
    assert_no_start(c)

    results =
      for(_ <- 1..4, do: Task.async(fn -> Backend.create(c) end))
      |> Task.await_many(10_000)

    observations =
      for {:ok, result} <- results do
        assert %{"workload" => "running", "starts" => 1, "phase" => "reply"} = result
        assert {:ok, receipt} = AgentBackendRequest.verify_response(c.create, result["receipt"])
        receipt
      end

    assert observations |> Enum.map(& &1["disposition"]) |> Enum.sort() ==
             ["created", "existing", "existing", "existing"]

    assert [backend_id] = observations |> Enum.map(& &1["backend_id"]) |> Enum.uniq()

    assert %{"workload" => "running", "starts" => 1, "receipt" => %{"backend_id" => ^backend_id}} =
             Backend.lookup(c)

    assert length(execution_directories(c)) == 1
    assert Log.head() == c.head
  end

  test "SIGKILL after native creation and before reply recovers the same live workload", c do
    assert {:ok, %{"phase" => "started", "exit_status" => 137} = killed} =
             Backend.create(c, :started)

    refute Map.has_key?(killed, "receipt")

    assert {:ok, %{phase: "leased", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(c.conn, c.effect)

    log_pid = GenServer.whereis(Log.server())
    assert is_pid(log_pid)
    restart_log()
    fresh_log_pid = GenServer.whereis(Log.server())
    assert is_pid(fresh_log_pid)
    refute fresh_log_pid == log_pid
    assert Log.head() == c.head

    assert %{"workload" => "running", "starts" => 1} = recovered = Backend.lookup(c)
    assert recovered["receiver_pid"] != killed["receiver_pid"]

    assert {:ok, %{"backend_id" => backend_id}} =
             AgentBackendRequest.verify_lookup_binding(c.create, recovered["receipt"])

    assert backend_id == killed["backend_id"]

    assert {:ok, %{"workload" => "running", "starts" => 1} = duplicate} = Backend.create(c)

    assert {:ok, %{"backend_id" => ^backend_id, "disposition" => "existing"}} =
             AgentBackendRequest.verify_response(c.create, duplicate["receipt"])

    assert {:ok, version} = Backend.attach(c, recovered)

    assert {:ok, %{backend_ref: ^backend_id, version: ^version, attempts: 1}} =
             Postgres.snapshot(c.conn, c.effect)

    assert {:error, :agent_launch_admission_refused} = Backend.create(c)
    assert execution_directories(c) == [backend_id]
    assert Log.head() == c.head

    evidence(c, "started-before-reply", %{
      "crash" => killed,
      "recovery" => recovered,
      "redelivery" => duplicate,
      "original_log_pid" => inspect(log_pid),
      "fresh_log_pid" => inspect(fresh_log_pid),
      "attached_version" => version
    })
  end

  test "a crash after reservation with no start witness holds the outcome", c do
    assert {:ok, %{"phase" => "reserved", "exit_status" => 137}} = Backend.create(c, :reserved)
    assert %{"workload" => "unknown", "starts" => 0} = recovered = Backend.lookup(c)

    assert {:ok, %{"backend_id" => backend_id}} =
             AgentBackendRequest.verify_lookup_binding(c.create, recovered["receipt"])

    assert {:ok, %{"workload" => "unknown", "starts" => 0} = retry} = Backend.create(c)

    assert {:ok, %{"backend_id" => ^backend_id, "disposition" => "existing"}} =
             AgentBackendRequest.verify_response(c.create, retry["receipt"])

    assert execution_directories(c) == []

    assert {:ok, %{phase: "leased", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(c.conn, c.effect)

    assert Log.head() == c.head
  end

  test "signed revocation before a delayed start needs no receiver fence to block creation", c do
    pending = Backend.hold(c.store, c.create)
    revoke(c)
    assert {:error, :agent_run_operator_revoked} = Backend.release(c, pending)
    assert_no_start(c)
    assert {:ok, %{phase: "leased", backend_ref: nil}} = Postgres.snapshot(c.conn, c.effect)
  end

  test "a receiver fence wins against a held create even with a fresh signed admission", c do
    pending = Backend.hold(c.store, c.create)
    assert %{"receipt" => %{"state" => "fenced", "backend_id" => nil}} = Backend.fence(c)
    assert {:ok, %{"receipt" => refusal}} = Backend.release(c, pending)

    assert {:error, :agent_backend_effect_fenced} =
             AgentBackendRequest.verify_response(c.create, refusal)

    assert %{"starts" => 0, "receipt" => %{"state" => "fenced"}} = Backend.lookup(c)
    assert execution_directories(c) == []
    assert Log.head() == c.head
  end

  test "revocation between signed replay and the locked start check refuses the old request", c do
    pending = Backend.hold(c.store, c.create)

    assert {:error, :signed_source_changed} =
             Backend.release(c, pending, fn -> revoke(c) end)

    assert_no_start(c)
  end

  test "stale plan digest cannot consume the first allocation slot", c do
    stale = Map.put(c.create, "plan_digest", String.duplicate("0", 64))
    pending = Backend.hold(c.store, stale)

    assert {:error, :agent_backend_admission_mismatch} = Backend.release(c, pending)
    assert_no_start(c)

    assert {:ok, %{"workload" => "running", "starts" => 1} = started} = Backend.create(c)
    assert {:ok, _} = AgentBackendRequest.verify_response(c.create, started["receipt"])
    assert Log.head() == c.head
  end

  test "a worker substituted for the signed artifact refuses before reservation", c do
    replacement = Path.join(c.store.directory, "replacement")
    File.write!(replacement, File.read!(c.store.worker.path) <> <<0>>)
    swapped = put_in(c.store.worker.path, replacement)
    assert {:ok, %{"error" => "fixture_worker_digest_changed"}} = Backend.create(swapped)
    assert_no_start(c)
  end

  for column <- ["lease_expires_at", "execution_deadline"] do
    test "#{column} expiring after replay blocks a delayed allocation", c do
      pending = Backend.hold(c.store, c.create)

      expire = fn ->
        assert %{num_rows: 1} =
                 Postgrex.query!(
                   c.conn,
                   "UPDATE agent_ops.execution_attempts SET #{unquote(column)}=clock_timestamp()-interval '1 second' WHERE effect_id=$1",
                   [c.effect]
                 )

        :ok
      end

      assert {:error, :fixture_claim_no_longer_live} = Backend.release(c, pending, expire)
      assert_no_start(c)
      assert Log.head() == c.head
    end
  end

  test "crash during cancellation keeps the fence and permits retry against the original worker",
       c do
    assert {:ok, %{"workload" => "running"}} = Backend.create(c)
    recovered = Backend.lookup(c)

    assert {:ok, %{"backend_id" => backend_id}} =
             AgentBackendRequest.verify_lookup_binding(c.create, recovered["receipt"])

    assert {:ok, version} = Backend.attach(c, recovered)
    pending = Backend.hold(c.store, c.create)
    revoke(c)
    withdrawn = Log.head()

    Process.put(WithdrawalHost, {c, backend_id, :fenced})
    key = c.request.run_key

    assert {:error, :cancellation_requires_reconciliation} =
             Coordinator.withdraw(c.conn, key, WithdrawalHost)

    assert_receive {:fixture_fence, %{"phase" => "fenced", "exit_status" => 137} = killed}

    assert %{"workload" => "running", "starts" => 1} = fenced_running = Backend.lookup(c)

    assert {:ok, %{"state" => "fenced", "future_creates_refused" => true}} =
             AgentBackendRequest.verify_lookup_binding(
               c.create,
               fenced_running["receipt"],
               backend_id
             )

    assert {:error, :agent_run_operator_revoked} = Backend.release(c, pending)
    lease = %{c.request.lease | version: version}

    assert {:error, :agent_run_operator_revoked} =
             Coordinator.submit_candidate(c.conn, key, WithdrawalHost, lease, "fixture output")

    Process.put(WithdrawalHost, {c, backend_id, :none})
    assert {:ok, :cancel_requested} = Coordinator.withdraw(c.conn, key, WithdrawalHost)
    assert_receive {:fixture_fence, %{"phase" => "reply"} = retried}

    stopped = await_stop(c, System.monotonic_time(:millisecond) + 2_000)
    assert %{"workload" => "stopped", "starts" => 1, "cancel_received" => true} = stopped
    assert stopped["receiver_pid"] != retried["receiver_pid"]

    assert {:ok, %{"state" => "fenced", "termination_verified" => false}} =
             AgentBackendRequest.verify_lookup_binding(c.create, stopped["receipt"], backend_id)

    assert {:ok, %{phase: "cancel_requested", backend_ref: ^backend_id, candidate_digest: nil}} =
             Postgres.snapshot(c.conn, c.effect)

    assert execution_directories(c) == [backend_id]
    assert Log.head() == withdrawn

    evidence(c, "cancel-retry", %{
      "crash" => killed,
      "fenced_workload" => fenced_running,
      "retry" => retried,
      "independent_observation" => stopped,
      "withdrawal_source_seq" => withdrawn.global_seq
    })
  end

  defp revoke(c) do
    event =
      signed_event(c.fixture.gov, "TaskOperatorRevokedV1", %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "authorization_event_id" => c.fixture.grant.event_id
      })

    assert {:ok, _} = Log.append(event)
    assert Log.head().global_seq == c.head.global_seq + 1
    :ok
  end

  defp assert_no_start(c) do
    assert %{"workload" => "unknown", "starts" => 0} = reply = Backend.lookup(c)
    assert {:ok, request} = AgentBackendRequest.lookup(c.effect, c.store.store_id)

    assert {:ok, %{"state" => "unknown", "backend_id" => nil}} =
             AgentBackendRequest.verify_response(request, reply["receipt"])

    assert execution_directories(c) == []
  end

  defp execution_directories(c),
    do: c.store.directory |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "agent-backend:"))

  defp await_stop(c, until) do
    result = Backend.lookup(c)

    if result["workload"] == "running" and System.monotonic_time(:millisecond) < until do
      Process.sleep(15)
      await_stop(c, until)
    else
      result
    end
  end

  defp evidence(c, name, fields) do
    assert :ok = Log.verify_chains()

    if directory = System.get_env("AGENT_BACKEND_EVIDENCE_DIR") do
      revision = System.fetch_env!("AGENT_LAUNCH_SOURCE_REVISION")

      fields =
        Map.merge(fields, %{
          "source_revision" => revision,
          "fixture" => "linux-restricted-process",
          "create" => c.create,
          "admission_source_seq" => c.admission.source_seq,
          "admission_source_hash" => Base.encode16(c.admission.source_hash, case: :lower),
          "signed_chains_verified" => true
        })

      File.mkdir_p!(directory)
      suffix = String.replace_prefix(c.store.store_id, "agent-backend-store:", "")

      File.write!(
        Path.join(directory, "execution-#{name}-#{suffix}.json"),
        Jason.encode!(fields, pretty: true) <> "\n"
      )
    end
  end
end
