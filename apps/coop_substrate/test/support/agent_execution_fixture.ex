defmodule CoopSubstrate.AgentExecutionFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias AgentOpsStore.Postgres
  alias CoopSubstrate.{AgentBackendReceiver, AgentBackendRequest, EventStore, Log}

  @directory Path.expand("../../../../experiments/agent_backend_receiver", __DIR__)
  @context %{environment: :staging}
  @timeout 5_000

  def compile_worker do
    directory = Path.join(System.tmp_dir!(), "agent-worker-" <> CoopSubstrate.ULID.generate())
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    worker = Path.join(directory, "worker")
    compiler = System.find_executable("cc") || raise "cc is required for the Linux fixture"

    assert {"", 0} =
             System.cmd(compiler, [
               "-std=c11",
               "-O2",
               "-Wall",
               "-Wextra",
               "-Werror",
               Path.join(@directory, "fixture_worker.c"),
               "-o",
               worker
             ])

    digest = Base.encode16(:crypto.hash(:sha256, File.read!(worker)), case: :lower)
    %{path: worker, sha256: digest}
  end

  def new_store(worker), do: Map.put(AgentBackendReceiver.new_store(), :worker, worker)

  def create(case_data, fault \\ :none) do
    release(case_data, hold(case_data.store, case_data.create, fault))
  end

  def hold(store, request, fault \\ :none) do
    env = System.find_executable("env") || raise "env is required for the Linux fixture"
    python = System.find_executable("python3") || raise "Python 3 is required for the fixture"

    port =
      Port.open({:spawn_executable, env}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 4_096},
        {:args,
         [
           "-i",
           python,
           Path.join(@directory, "execution_fixture.py"),
           "--db",
           store.db,
           "--worker",
           store.worker.path,
           "--worker-sha256",
           store.worker.sha256,
           "--fault",
           Atom.to_string(fault)
         ]}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert Port.command(port, Jason.encode!(request) <> "\n")
    assert %{"phase" => "waiting"} = receive_line(port)
    %{port: port, pid: pid, request: request, fault: Atom.to_string(fault)}
  end

  def release(case_data, pending, before_lock \\ fn -> :ok end) do
    with_authority(case_data, pending.request, before_lock, fn _tx, start_by ->
      {:ok, respond(pending, %{"start_by_us" => DateTime.to_unix(start_by, :microsecond)})}
    end)
  after
    if Port.info(pending.port), do: Port.close(pending.port)
  end

  def lookup(case_data) do
    {:ok, request} = AgentBackendRequest.lookup(case_data.effect, case_data.store.store_id)
    run(case_data.store, request, :none)
  end

  def fence(case_data, fault \\ :none) do
    {:ok, request} = AgentBackendRequest.fence(case_data.effect, case_data.store.store_id)
    run(case_data.store, request, fault)
  end

  def attach(case_data, %{"workload" => "running", "starts" => 1, "receipt" => raw}) do
    with {:ok, receipt} <- AgentBackendRequest.verify_lookup_binding(case_data.create, raw),
         true <- receipt["state"] == "accepted" or {:error, :fixture_execution_fenced} do
      with_authority(case_data, case_data.create, fn -> :ok end, fn tx, _start_by ->
        admission = case_data.admission
        lease = case_data.request.lease

        Postgres.attach_backend(
          tx,
          case_data.effect,
          admission.version,
          lease.epoch,
          lease.token,
          receipt["backend_id"]
        )
      end)
    end
  end

  # This trusted test host uses the real replay guard. The second lock check
  # closes the gap between replay returning and the fixture being released.
  # No production path holds a canonical lock across provider I/O.
  defp with_authority(case_data, wire, before_lock, perform) do
    head = Log.head()
    request = case_data.request
    parameters = request.plan.profile.manifest["parameters"]

    with true <-
           parameters["fixture_worker_sha256"] == case_data.store.worker.sha256 or
             {:error, :fixture_worker_digest_unapproved},
         {:ok, receipt} <- Log.admit_agent_launch(@context, request),
         true <-
           Map.delete(receipt, :disposition) == Map.delete(case_data.admission, :disposition) or
             {:error, :admission_changed},
         {:ok, ^wire} <-
           AgentBackendRequest.create(request.plan, receipt, case_data.store.store_id) do
      :ok = before_lock.()
      under_canonical_lock(head, receipt, request.lease, perform)
    else
      {:ok, _different} -> {:error, :agent_backend_admission_mismatch}
      {:error, _} = error -> error
    end
  end

  defp under_canonical_lock(head, admission, lease, perform) do
    config = Elixir.EventStore.Config.lookup(EventStore)
    "public" = Keyword.get(config, :schema, "public")

    result =
      Postgrex.transaction(
        Keyword.fetch!(config, :conn),
        fn tx ->
          Postgrex.query!(tx, "SET LOCAL lock_timeout = '2s'", [], timeout: @timeout)

          with :ok <- check_source(tx, head),
               {:ok, start_by} <- lock_attempt(tx, admission, lease) do
            perform.(tx, start_by)
          else
            {:error, reason} -> Postgrex.rollback(tx, reason)
          end
        end,
        timeout: @timeout
      )

    case result do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp check_source(tx, head) do
    with {:ok, %{rows: [[stream_id, seq]]}} <-
           Postgrex.query(
             tx,
             """
             SELECT stream_id, stream_version FROM public.streams
              WHERE stream_uuid = 'ledger' AND deleted_at IS NULL FOR UPDATE
             """,
             [],
             timeout: @timeout
           ),
         true <- head.global_seq == seq,
         {:ok, %{rows: [[data]]}} <-
           Postgrex.query(
             tx,
             """
             SELECT e.data FROM public.events e JOIN public.stream_events se ON se.event_id=e.event_id
              WHERE se.stream_id=$1 AND se.stream_version=$2
             """,
             [stream_id, seq],
             timeout: @timeout
           ),
         true <- head.global_hash == :crypto.hash(:sha256, data) do
      :ok
    else
      _ -> {:error, :signed_source_changed}
    end
  end

  defp lock_attempt(tx, admission, lease) do
    sql = """
    SELECT LEAST(lease_expires_at, execution_deadline)
      FROM agent_ops.execution_attempts
     WHERE effect_id=$1 AND row_version=$2 AND attempt_epoch=$3
       AND descriptor_digest=$4 AND lease_token_sha256=$5 AND execution_deadline=$6
       AND phase='leased' AND backend_ref IS NULL AND lease_expires_at IS NOT NULL
     FOR UPDATE
    """

    params = [
      admission.effect_id,
      admission.version,
      admission.epoch,
      admission.descriptor_digest,
      :crypto.hash(:sha256, lease.token),
      admission.execution_deadline
    ]

    with {:ok, %{rows: [[start_by]]}} <- Postgrex.query(tx, sql, params, timeout: @timeout),
         {:ok, %{rows: [[now]]}} <-
           Postgrex.query(tx, "SELECT clock_timestamp()", [], timeout: @timeout),
         :gt <- DateTime.compare(start_by, now) do
      {:ok, start_by}
    else
      _ -> {:error, :fixture_claim_no_longer_live}
    end
  end

  defp run(store, request, fault) do
    pending = hold(store, request, fault)

    try do
      respond(pending, %{})
    after
      if Port.info(pending.port), do: Port.close(pending.port)
    end
  end

  defp respond(pending, permit) do
    assert Port.command(pending.port, Jason.encode!(permit) <> "\n")

    case receive_line(pending.port) do
      %{"phase" => "reply"} = reply ->
        assert exit_status(pending.port) == 0
        Map.put(reply, "receiver_pid", pending.pid)

      %{"phase" => phase} = barrier when phase == pending.fault ->
        assert {"", 0} = System.cmd("kill", ["-KILL", Integer.to_string(pending.pid)])
        status = exit_status(pending.port)
        assert status == 137
        Map.merge(barrier, %{"receiver_pid" => pending.pid, "exit_status" => status})
    end
  end

  defp receive_line(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
      {^port, {:data, {:noeol, _}}} -> raise "oversized fixture response"
      {^port, {:exit_status, status}} -> raise "fixture exited before responding: #{status}"
    after
      @timeout -> raise "fixture did not respond"
    end
  end

  defp exit_status(port) do
    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _}} -> raise "unexpected extra fixture response"
    after
      @timeout -> raise "fixture did not exit"
    end
  end
end
