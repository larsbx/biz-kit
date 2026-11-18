# Disposable two-process persistence acceptance. Run from apps/coop_substrate
# with MIX_ENV=test and --no-start. The named test database is checked before
# any destructive fixture setup. No real adapter or external backend is used.

defmodule AgentLaunchAdmissionProbe.Adapter do
  @behaviour AgentCore.ExecutionPort
  @behaviour AgentCore.RecoveryPort
  def launch(_, _, _), do: raise("admission must not invoke an execution adapter")
  def poll(_), do: {:error, :no_backend_in_admission_probe}
  def cancel(_, _), do: {:error, :no_backend_in_admission_probe}
  def lookup(_, _), do: {:error, :no_backend_in_admission_probe}
end

defmodule AgentLaunchAdmissionProbe do
  alias AgentCore.Preflight
  alias AgentOpsStore.Postgres
  alias CoopSubstrate.{AgentStagingFixture, AgentStagingSQL, Canonical, Log, LogCase}
  alias TaskCore.AgentRuns

  @key {"chapter-genesis", "tenant-1", "project-1", "run-1"}

  def run("prepare", receipt_file) do
    disposable!()
    {:ok, _} = Application.ensure_all_started(:coop_substrate)
    LogCase.truncate_store!()
    LogCase.restart_log()
    AgentStagingSQL.setup!()
    fixture = AgentStagingFixture.prepare(fn _cleanup -> :ok end)
    {registry, requirements} = profile()
    manifest = registry["approved-profile"].manifest
    read = AgentStagingFixture.access_grant(fixture, "read")
    execute = AgentStagingFixture.access_grant(fixture, "execute")
    {:ok, _} = Log.append([read, execute])

    request =
      AgentStagingFixture.request(fixture, %{
        "execution_profile_digest" => {:bytes, Canonical.hash!(manifest)},
        "max_duration_ms" => 300_000
      })

    {:ok, _} = Log.append(request)
    {:ok, conn} = LogCase.raw_conn()
    grants = %{read: read.event_id, execute: execute.event_id}
    {gate, _} = Log.read_snapshot()
    {:ok, run} = AgentRuns.authorized?(gate.orchestration, @key, grants)
    {:ok, plan} = Preflight.prepare(run, registry, &Canonical.hash!/1, requirements)
    {:ok, :new} = Postgres.register(conn, plan)
    {:ok, row} = Postgres.snapshot(conn, plan.effect_id)

    {:ok, lease} =
      Postgres.claim(conn, plan.effect_id, row.version, "durability-probe", 300_000, 2)

    :ok = Postgres.validate_launch_lease(conn, plan.effect_id, lease)

    {:ok, admission} =
      Log.admit_agent_launch(%{environment: :staging}, %{
        run_key: @key,
        grants: grants,
        registry: registry,
        requirements: requirements,
        plan: plan,
        lease: lease
      })

    :admitted = admission.disposition

    revocation =
      LogCase.signed_event(fixture.gov, "TaskOperatorRevokedV1", %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "authorization_event_id" => fixture.grant.event_id
      })

    {:ok, _} = Log.append(revocation)
    {:ok, _} = Postgres.request_cancel(conn, plan.effect_id, admission.version)
    :ok = Log.verify_chains()
    snapshot = snapshot!(conn, plan.effect_id)

    receipt = %{
      "schema" => "bizkit.agent-launch-admission-restart.v1",
      "source_revision" => System.fetch_env!("AGENT_LAUNCH_SOURCE_REVISION"),
      "prepare_vm" => System.pid(),
      "artifact_dir" => Application.fetch_env!(:coop_substrate, :artifact_dir),
      "effect_id" => plan.effect_id,
      "read_grant" => read.event_id,
      "execute_grant" => execute.event_id,
      "revocation_event_id" => revocation.event_id,
      "postgres_started_at" => postgres_started_at(conn),
      "snapshot" => snapshot,
      "ledger_head" => json_head(Log.head())
    }

    # The receipt contains no signing seed, token, password or backend credential.
    File.write!(receipt_file, Jason.encode_to_iodata!(receipt, pretty: true))
    GenServer.stop(conn)
    IO.puts("PREPARED: committed signed history, immutable admission and cancellation")
  end

  def run("verify", receipt_file) do
    disposable!()
    expected = receipt_file |> File.read!() |> Jason.decode!()
    "bizkit.agent-launch-admission-restart.v1" = expected["schema"]
    true = expected["source_revision"] == System.fetch_env!("AGENT_LAUNCH_SOURCE_REVISION")
    true = expected["prepare_vm"] != System.pid()
    Application.put_env(:coop_substrate, :artifact_dir, expected["artifact_dir"])
    {:ok, _} = Application.ensure_all_started(:coop_substrate)
    :ok = Log.verify_chains()
    true = expected["ledger_head"] == json_head(Log.head())
    {:ok, conn} = LogCase.raw_conn()
    true = expected["postgres_started_at"] != postgres_started_at(conn)
    actual = snapshot!(conn, expected["effect_id"])
    true = actual == expected["snapshot"]
    "cancel_requested" = actual["attempt"]["phase"]
    1 = actual["attempt"]["attempts"]
    nil = actual["attempt"]["backend_ref"]

    {gate, _} = Log.read_snapshot()
    grants = %{read: expected["read_grant"], execute: expected["execute_grant"]}
    {:error, _} = AgentRuns.authorized?(gate.orchestration, @key, grants)
    {:ok, events} = Log.read_all()
    true = Enum.any?(events, &(&1.event_id == expected["revocation_event_id"]))

    source = actual["admission"]
    event = Enum.find(events, &(&1.global_seq == source["source_seq"]))
    {:ok, event_hash} = CoopSubstrate.Protocol.Envelope.event_hash(event)
    true = Base.encode16(event_hash, case: :lower) == source["source_hash"]

    GenServer.stop(conn)

    IO.puts(
      "VERIFIED: fresh VM and SQL connection recovered identical signed source/admission/cancellation"
    )

    IO.puts(
      "NO BACKEND CLAIM: no execution adapter, process-start, power-loss or failover acceptance"
    )
  end

  defp disposable! do
    config = Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)
    "coop_substrate_eventstore_test" = config[:database]
    :test = Mix.env()
  end

  defp json_head(head) do
    %{"seq" => head.global_seq, "hash" => Base.encode16(head.global_hash, case: :lower)}
  end

  defp postgres_started_at(conn) do
    %{rows: [[started_at]]} = Postgrex.query!(conn, "SELECT pg_postmaster_start_time()::text", [])
    started_at
  end

  defp snapshot!(conn, effect) do
    %{rows: [[receipt]]} =
      Postgrex.query!(
        conn,
        """
        SELECT json_build_object(
          'admission', json_build_object(
            'admission_id', j.admission_id, 'effect_id', j.effect_id,
            'epoch', j.epoch, 'claim_version', j.claim_version, 'version', j.version,
            'source_seq', j.source_seq, 'source_hash', encode(j.source_hash, 'hex'),
            'descriptor_digest', encode(j.descriptor_digest, 'hex'),
            'plan_digest', encode(j.plan_digest, 'hex'),
            'read_grant', j.read_grant, 'execute_grant', j.execute_grant,
            'admitted_at', j.admitted_at, 'execution_deadline', j.execution_deadline),
          'attempt', json_build_object(
            'effect_id', a.effect_id, 'phase', a.phase, 'version', a.row_version,
            'epoch', a.attempt_epoch, 'attempts', a.attempts, 'backend_ref', a.backend_ref,
            'descriptor_digest', encode(a.descriptor_digest, 'hex')))
        FROM agent_ops.launch_admissions j
        JOIN agent_ops.execution_attempts a USING (effect_id)
        WHERE j.effect_id = $1
        """,
        [effect]
      )

    receipt
  end

  defp profile do
    features = ~w(text idempotent_launch_v1 effect_lookup_v1 cancellation_v1 bounded_results_v1)

    manifest = %{
      "id" => "approved-profile",
      "version" => 1,
      "adapter_module" => Atom.to_string(AgentLaunchAdmissionProbe.Adapter),
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

    profile = %{
      id: "approved-profile",
      approved: true,
      adapter: AgentLaunchAdmissionProbe.Adapter,
      manifest: manifest
    }

    requirements = %{
      "features" => features,
      "data_classes" => ["internal"],
      "region" => "local",
      "max_duration_ms" => 300_000,
      "max_output_bytes" => 4096
    }

    {%{"approved-profile" => profile}, requirements}
  end
end

case System.argv() do
  [phase, receipt_file] when phase in ["prepare", "verify"] ->
    AgentLaunchAdmissionProbe.run(phase, receipt_file)

  _ ->
    raise "usage: mix run --no-start agent_launch_admission_probe.exs prepare|verify RECEIPT.json"
end
