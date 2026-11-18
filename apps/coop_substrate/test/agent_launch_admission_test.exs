defmodule CoopSubstrate.AgentLaunchAdmissionTest do
  @moduledoc """
  Signed source ordering and native SQL admission, without backend execution.

  The test adapter raises on every effect callback. A committed receipt is an
  operational decision, not a sandbox, a termination receipt or business fact.
  Session recovery below is not a claim about database power-loss durability.
  """
  use CoopSubstrate.LogCase, async: false

  alias AgentCore.{Attempts, Preflight}
  alias AgentOpsStore.Postgres
  alias CoopSubstrate.{AgentStagingFixture, AgentStagingSQL, Canonical, Log}
  alias CoopSubstrate.Projections.Tasks, as: Projection
  alias TaskCore.AgentRuns

  @key {"chapter-genesis", "tenant-1", "project-1", "run-1"}
  @context %{environment: :staging}

  defmodule NoBackend do
    @behaviour AgentCore.ExecutionPort
    @behaviour AgentCore.RecoveryPort

    def launch(_, _, _), do: raise("admission must not launch a backend")
    def poll(_), do: raise("admission must not poll a backend")
    def cancel(_, _), do: raise("admission must not cancel a backend")
    def lookup(_, _), do: raise("admission must not look up a backend")
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
          "max_duration_ms" => 30_000,
          "max_output_bytes" => 4096
        }
      }
    }

    profile = %{id: "approved-profile", approved: true, adapter: NoBackend, manifest: manifest}
    read = AgentStagingFixture.access_grant(fixture, "read")
    execute = AgentStagingFixture.access_grant(fixture, "execute")

    intent =
      AgentStagingFixture.request(fixture, %{
        "execution_profile_digest" => {:bytes, Canonical.hash!(manifest)}
      })

    assert {:ok, _} = Log.append([read, execute, intent])

    grants = %{read: read.event_id, execute: execute.event_id}
    registry = %{"approved-profile" => profile}

    requirements = %{
      "features" => features,
      "data_classes" => ["internal"],
      "region" => "local",
      "max_duration_ms" => 30_000,
      "max_output_bytes" => 4096
    }

    assert {:ok, state} = Log.replay(Projection)
    assert {:ok, run} = AgentRuns.authorized?(state, @key, grants)
    assert {:ok, plan} = Preflight.prepare(run, registry, &Canonical.hash!/1, requirements)
    conn = connection(:admission_connection)
    assert {:ok, :new} = Postgres.register(conn, plan)
    assert {:ok, row} = Postgres.snapshot(conn, plan.effect_id)

    assert {:ok, lease} =
             Postgres.claim(conn, plan.effect_id, row.version, "admission-test", 30_000, 2)

    assert :ok = Postgres.validate_launch_lease(conn, plan.effect_id, lease)

    request = %{
      run_key: @key,
      grants: grants,
      registry: registry,
      requirements: requirements,
      plan: plan,
      lease: lease
    }

    %{conn: conn, fixture: fixture, request: request, effect: plan.effect_id, head: Log.head()}
  end

  test "one committed receipt binds the source and original claim across lost replies and session restart",
       c do
    assert {:ok, receipt} = Log.admit_agent_launch(@context, c.request)
    assert receipt.disposition == :admitted
    assert receipt.effect_id == c.effect

    assert receipt.admission_id ==
             "agent-admission:" <> Base.encode16(:crypto.hash(:sha256, c.effect), case: :lower)

    assert receipt.source_seq == c.head.global_seq
    assert receipt.source_hash == c.head.global_hash
    assert receipt.epoch == c.request.lease.epoch
    assert receipt.claim_version == c.request.lease.version
    assert receipt.version == c.request.lease.version + 1
    assert {:ok, receipt.descriptor_digest} == Attempts.descriptor_digest(c.request.plan)
    assert is_binary(receipt.plan_digest) and byte_size(receipt.plan_digest) == 32
    assert DateTime.compare(receipt.admitted_at, receipt.execution_deadline) == :lt
    refute Map.has_key?(receipt, :token)
    assert Log.head() == c.head

    [stored] = admissions(c.conn, c.effect)
    assert Enum.take(stored, 11) == receipt_fields(receipt)
    assert Enum.drop(stored, 11) == [c.request.grants.read, c.request.grants.execute]

    assert {:ok, repeated} = Log.admit_agent_launch(@context, c.request)
    assert repeated.disposition == :existing
    assert Map.delete(repeated, :disposition) == Map.delete(receipt, :disposition)

    stop_supervised!(:admission_connection)
    restart_log()
    fresh = connection(:fresh_admission_connection)
    assert {:ok, recovered} = Log.admit_agent_launch(@context, c.request)
    assert recovered == repeated
    assert admissions(fresh, c.effect) == [stored]

    assert {:ok, %{phase: "leased", backend_ref: nil, attempts: 1, version: version}} =
             Postgres.snapshot(fresh, c.effect)

    assert version == receipt.version
    assert Log.head() == c.head
    assert :ok = Log.verify_chains()
  end

  test "signed operator revocation after the old lease check refuses admission", c do
    assert {:ok, _} = Log.append(operator_revocation(c))
    # SQL still considers this claim live: only signed replay sees the revocation.
    assert :ok = Postgres.validate_launch_lease(c.conn, c.effect, c.request.lease)
    assert {:error, :agent_run_operator_revoked} = Log.admit_agent_launch(@context, c.request)
    assert_no_admission(c)
    restart_log()
    assert {:error, :agent_run_operator_revoked} = Log.admit_agent_launch(@context, c.request)
    assert_no_admission(c)
  end

  test "signed task version change after the old lease check refuses admission", c do
    start =
      signed_event(c.fixture.op, "TaskStartedV1", %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "task_id" => "task-1",
        "principal_id" => "operator-1",
        "authorization_event_id" => c.fixture.grant.event_id,
        "lifecycle_version" => 1,
        "expected_version" => 7
      })

    assert {:ok, _} = Log.append(start)
    assert :ok = Postgres.validate_launch_lease(c.conn, c.effect, c.request.lease)
    assert {:error, :stale_agent_run_task} = Log.admit_agent_launch(@context, c.request)
    assert_no_admission(c)
  end

  test "a changed host profile cannot reuse the signed intent digest", c do
    # Host configuration is a supplied snapshot, not a newly signed approval.
    changed =
      update_in(
        c.request,
        [:registry, "approved-profile", :manifest, "parameters"],
        &Map.put(&1, "revision", 2)
      )

    assert {:error, :execution_profile_digest_mismatch} =
             Log.admit_agent_launch(@context, changed)

    assert Log.head() == c.head
    assert_no_admission(c)
  end

  test "an alternate appender with stale signed replay cannot admit against an advanced ledger",
       c do
    stale = alternate_log()
    assert Log.head(stale) == c.head
    assert {:ok, _} = Log.append(operator_revocation(c))

    assert {:error, :unverified_launch_source} =
             Log.admit_agent_launch(@context, c.request, stale)

    assert {:error, :agent_run_operator_revoked} = Log.admit_agent_launch(@context, c.request)
    assert_no_admission(c)
  end

  test "equal source sequence with a wrong cached record hash is refused", c do
    server = GenServer.whereis(Log.server())
    original = :sys.get_state(server)
    :sys.replace_state(server, &%{&1 | head: %{&1.head | global_hash: <<0::256>>}})

    try do
      assert Log.head().global_seq == c.head.global_seq
      assert {:error, :unverified_launch_source} = Log.admit_agent_launch(@context, c.request)
      assert_no_admission(c)
    after
      :sys.replace_state(server, fn _ -> original end)
    end
  end

  test "wrong token, claim version and epoch cannot borrow the live claim", c do
    for lease <- [
          %{c.request.lease | token: :crypto.strong_rand_bytes(32)},
          %{c.request.lease | version: c.request.lease.version + 1},
          %{c.request.lease | epoch: c.request.lease.epoch + 1}
        ] do
      assert {:error, :agent_launch_admission_refused} =
               Log.admit_agent_launch(@context, %{c.request | lease: lease})

      assert_no_admission(c)
    end

    assert :ok = Postgres.validate_launch_lease(c.conn, c.effect, c.request.lease)
  end

  test "independently committed SQL cancellation after validation refuses admission", c do
    other = connection(:cancelling_connection)
    assert {:ok, _} = Postgres.request_cancel(other, c.effect, c.request.lease.version)
    assert {:error, :agent_launch_admission_refused} = Log.admit_agent_launch(@context, c.request)
    assert admissions(c.conn, c.effect) == []

    assert {:ok, %{phase: "cancel_requested", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(c.conn, c.effect)
  end

  for column <- ["lease_expires_at", "execution_deadline"] do
    test "an independently expired #{column} refuses admission", c do
      # Only the disposable test clock is changed; no timing sleep is used.
      Postgrex.query!(
        c.conn,
        "UPDATE agent_ops.execution_attempts SET #{unquote(column)}=clock_timestamp()-interval '1 second' WHERE effect_id=$1",
        [c.effect]
      )

      assert {:error, :agent_launch_admission_refused} =
               Log.admit_agent_launch(@context, c.request)

      assert_no_admission(c)
    end
  end

  test "production and caller-supplied SQL contexts or transactions are refused", c do
    assert {:error, :staging_only} =
             Log.admit_agent_launch(%{environment: :production}, c.request)

    for context <- [
          nil,
          %{},
          %{environment: :staging, connection: c.conn},
          %{environment: :staging, schema: "public"}
        ] do
      assert {:error, :invalid_launch_admission_context} =
               Log.admit_agent_launch(context, c.request)
    end

    assert {:ok, :refused} =
             Postgrex.transaction(c.conn, fn transaction ->
               assert {:error, :invalid_launch_admission_context} =
                        Log.admit_agent_launch(
                          %{environment: :staging, transaction: transaction},
                          c.request
                        )

               assert {:error, :invalid_launch_admission_request} =
                        Log.admit_agent_launch(
                          @context,
                          Map.put(c.request, :connection, transaction)
                        )

               :refused
             end)

    assert_no_admission(c)
  end

  test "mutable application configuration cannot redirect the running canonical store", c do
    original = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)

    on_exit(fn ->
      Application.put_env(:coop_substrate, CoopSubstrate.EventStore, original)
    end)

    Application.put_env(
      :coop_substrate,
      CoopSubstrate.EventStore,
      Keyword.merge(original,
        database: "not_the_running_canonical_store",
        schema: "not_the_running_canonical_schema"
      )
    )

    assert {:ok, receipt} = Log.admit_agent_launch(@context, c.request)
    assert receipt.source_seq == c.head.global_seq
    assert receipt.source_hash == c.head.global_hash
    assert [stored] = admissions(c.conn, c.effect)
    assert Enum.take(stored, 11) == receipt_fields(receipt)
    assert Log.head() == c.head
  end

  test "changed valid host requirements cannot replay an existing exact-plan receipt", c do
    assert {:ok, original} = Log.admit_agent_launch(@context, c.request)
    [stored] = admissions(c.conn, c.effect)
    requirements = Map.put(c.request.requirements, "features", ["text"])
    assert {:ok, state} = Log.replay(Projection)
    assert {:ok, run} = AgentRuns.authorized?(state, @key, c.request.grants)

    assert {:ok, changed_plan} =
             Preflight.prepare(run, c.request.registry, &Canonical.hash!/1, requirements)

    refute changed_plan == c.request.plan
    # These valid plans collide under the older, narrower operational descriptor.
    assert Attempts.descriptor_digest(changed_plan) ==
             Attempts.descriptor_digest(c.request.plan)

    changed = %{c.request | plan: changed_plan, requirements: requirements}
    assert {:error, :agent_launch_admission_refused} = Log.admit_agent_launch(@context, changed)
    assert admissions(c.conn, c.effect) == [stored]
    assert {:ok, repeated} = Log.admit_agent_launch(@context, c.request)
    assert repeated.plan_digest == original.plan_digest
    assert repeated.disposition == :existing
    assert Log.head() == c.head
  end

  test "the exact trusted request, plan and independent access grants are required", c do
    for request <- [
          Map.delete(c.request, :lease),
          Map.put(c.request, :callback, fn -> flunk("caller callback") end),
          put_in(c.request, [:lease, :token], <<0>>)
        ] do
      assert {:error, :invalid_launch_admission_request} =
               Log.admit_agent_launch(@context, request)
    end

    for plan <- [
          %{c.request.plan | effect_id: "agent-run:other"},
          put_in(c.request.plan, [:execution, :ticket, "task_version"], 8)
        ] do
      assert {:error, :agent_launch_plan_changed} =
               Log.admit_agent_launch(@context, %{c.request | plan: plan})
    end

    for permission <- [:read, :execute] do
      request = put_in(c.request, [:grants, permission], "missing-grant")
      assert {:error, _} = Log.admit_agent_launch(@context, request)
    end

    assert_no_admission(c)
  end

  test "ordinary SQL updates and deletes cannot rewrite an admitted receipt", c do
    assert {:ok, _} = Log.admit_agent_launch(@context, c.request)
    [stored] = admissions(c.conn, c.effect)

    for statement <- [
          "UPDATE agent_ops.launch_admissions SET source_seq=source_seq WHERE effect_id=$1",
          "DELETE FROM agent_ops.launch_admissions WHERE effect_id=$1"
        ] do
      assert {:error, %Postgrex.Error{}} = Postgrex.query(c.conn, statement, [c.effect])
      assert admissions(c.conn, c.effect) == [stored]
    end
  end

  test "cancellation after admission preserves historical evidence and prevents re-admission",
       c do
    assert {:ok, receipt} = Log.admit_agent_launch(@context, c.request)
    [stored] = admissions(c.conn, c.effect)
    assert {:ok, _} = Postgres.request_cancel(c.conn, c.effect, receipt.version)
    assert {:error, :agent_launch_admission_refused} = Log.admit_agent_launch(@context, c.request)
    restart_log()
    assert {:error, :agent_launch_admission_refused} = Log.admit_agent_launch(@context, c.request)
    assert admissions(c.conn, c.effect) == [stored]

    assert {:ok, %{phase: "cancel_requested", backend_ref: nil, attempts: 1}} =
             Postgres.snapshot(c.conn, c.effect)

    assert Log.head() == c.head
  end

  test "an admission holding the ledger row orders before a genuinely independent revoking appender",
       c do
    other_log = alternate_log()
    observer = connection(:lock_observer)
    blocker = connection(:attempt_blocker)

    {locker, blocker_pid} =
      hold_lock(
        blocker,
        "SELECT effect_id FROM agent_ops.execution_attempts WHERE effect_id=$1 FOR UPDATE",
        [c.effect]
      )

    try do
      admitting = Task.async(fn -> Log.admit_agent_launch(@context, c.request) end)
      admission_pid = await_blocked(observer, blocker_pid, "%FROM agent_ops.admit_launch%")

      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
               Postgrex.query(
                 observer,
                 "SELECT stream_id FROM streams WHERE stream_uuid='ledger' FOR UPDATE NOWAIT",
                 []
               )

      revoking = Task.async(fn -> Log.append(operator_revocation(c), other_log) end)
      appender_pid = await_blocked(observer, admission_pid)
      assert appender_pid != admission_pid
      send(locker.pid, :release)

      assert {:ok, receipt} = Task.await(admitting, 5_000)
      assert receipt.source_seq == c.head.global_seq
      assert receipt.source_hash == c.head.global_hash
      assert {:ok, [revocation]} = Task.await(revoking, 5_000)
      assert revocation.global_seq == receipt.source_seq + 1

      assert {:error, :agent_run_operator_revoked} =
               Log.admit_agent_launch(@context, c.request, other_log)

      assert length(admissions(observer, c.effect)) == 1
      assert :ok = Log.verify_chains()
    after
      send(locker.pid, :release)
      assert {:ok, :released} = Task.await(locker, 5_000)
    end
  end

  test "an independent revocation queued first advances the locked source before admission", c do
    other_log = alternate_log()
    observer = connection(:source_lock_observer)
    blocker = connection(:source_blocker)

    {locker, blocker_pid} =
      hold_lock(
        blocker,
        "SELECT stream_id FROM streams WHERE stream_uuid='ledger' FOR UPDATE",
        []
      )

    try do
      revoking = Task.async(fn -> Log.append(operator_revocation(c), other_log) end)
      appender_pid = await_blocked(observer, blocker_pid)
      admitting = Task.async(fn -> Log.admit_agent_launch(@context, c.request) end)
      admission_pid = await_blocked(observer, appender_pid, "%stream_uuid = 'ledger'%FOR UPDATE%")
      assert admission_pid != appender_pid
      send(locker.pid, :release)

      assert {:ok, [revocation]} = Task.await(revoking, 5_000)
      assert revocation.global_seq == c.head.global_seq + 1
      assert {:error, :unverified_launch_source} = Task.await(admitting, 5_000)

      assert {:error, :agent_run_operator_revoked} =
               Log.admit_agent_launch(@context, c.request, other_log)

      assert_no_admission(c)
      assert :ok = Log.verify_chains()
    after
      send(locker.pid, :release)
      assert {:ok, :released} = Task.await(locker, 5_000)
    end
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

  defp alternate_log do
    start_supervised!(
      Supervisor.child_spec({Log, name: __MODULE__.AlternateLog}, id: :alternate_admission_log)
    )
  end

  defp operator_revocation(c) do
    signed_event(c.fixture.gov, "TaskOperatorRevokedV1", %{
      "tenant_id" => "tenant-1",
      "project_id" => "project-1",
      "authorization_event_id" => c.fixture.grant.event_id
    })
  end

  defp assert_no_admission(c) do
    assert admissions(c.conn, c.effect) == []

    assert {:ok, %{phase: "leased", backend_ref: nil, attempts: 1, version: version}} =
             Postgres.snapshot(c.conn, c.effect)

    assert version == c.request.lease.version
    assert :ok = Log.verify_chains()
  end

  defp admissions(conn, effect) do
    Postgrex.query!(
      conn,
      """
      SELECT admission_id, effect_id, epoch, claim_version, version, source_seq,
           source_hash, descriptor_digest, plan_digest, admitted_at, execution_deadline,
             read_grant, execute_grant
        FROM agent_ops.launch_admissions WHERE effect_id=$1
      """,
      [effect]
    ).rows
  end

  defp receipt_fields(receipt) do
    Enum.map(
      [
        :admission_id,
        :effect_id,
        :epoch,
        :claim_version,
        :version,
        :source_seq,
        :source_hash,
        :descriptor_digest,
        :plan_digest,
        :admitted_at,
        :execution_deadline
      ],
      &Map.fetch!(receipt, &1)
    )
  end

  defp hold_lock(conn, sql, params) do
    parent = self()

    task =
      Task.async(fn ->
        Postgrex.transaction(
          conn,
          fn transaction ->
            Postgrex.query!(transaction, sql, params)
            %{rows: [[backend_pid]]} = Postgrex.query!(transaction, "SELECT pg_backend_pid()", [])
            send(parent, {:row_locked, self(), backend_pid})

            receive do
              :release -> :released
            after
              7_000 -> flunk("lock barrier was not released")
            end
          end,
          timeout: 10_000
        )
      end)

    assert_receive {:row_locked, pid, backend_pid}, 2_000
    assert pid == task.pid
    {task, backend_pid}
  end

  defp await_blocked(conn, blocker, pattern \\ "%") do
    await_blocked(conn, blocker, pattern, System.monotonic_time(:millisecond) + 1_000)
  end

  defp await_blocked(conn, blocker, pattern, deadline) do
    result =
      Postgrex.query!(
        conn,
        """
        SELECT pid FROM pg_stat_activity
         WHERE datname=current_database() AND pid<>pg_backend_pid()
           AND wait_event_type='Lock' AND $1::integer=ANY(pg_blocking_pids(pid))
           AND query LIKE $2 ORDER BY pid
        """,
        [blocker, pattern]
      )

    case result.rows do
      [[pid] | _] ->
        pid

      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          await_blocked(conn, blocker, pattern, deadline)
        else
          flunk("independent SQL lock wait was not observed")
        end
    end
  end
end
