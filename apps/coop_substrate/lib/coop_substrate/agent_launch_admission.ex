defmodule CoopSubstrate.AgentLaunchAdmission do
  @moduledoc """
  Staging-only, source-ordered durable admission of an agent launch request.

  Called by Log with its own verified head and admission gate. The actual
  canonical ledger stream row is locked and compared with that head before
  current TaskCore authority and the exact execution plan are checked. The
  operational admission is then committed under the same transaction, after
  the attempt-row lock. A competing ledger append therefore orders before or
  after this admission; a stale appender cannot admit from its cached gate.

  The connection pool and schema come only from the running canonical
  EventStore's cached configuration, exactly as canonical append resolves them.
  Re-reading mutable application configuration or reconnecting to an endpoint
  could target a different database while the canonical pool remains unchanged.
  Callers cannot substitute a database, connection, transaction or effect
  callback. No adapter is invoked, no canonical event is appended, and no
  backend process is allocated here. The receipt identifies an operational
  admission, not execution, termination or business authority.

  The trusted host supplies an approved registry and requirements snapshot and
  must obtain consent before calling. These host policies are not serialized
  by the ledger lock. A separate canonical digest binds the complete closed
  plan, including the approved manifest and host requirements. Only its digest
  is persisted; reconstructing it requires the retained approved source data.
  The exact plan and manifest digest are bound, but this
  module does not make mutable host approval or external execution atomic with
  signed revocation.
  """

  alias AgentCore.{Attempts, Preflight, RecoveryPort}
  alias CoopSubstrate.Canonical
  alias TaskCore.AgentRuns

  @timeout 5_000
  @schema ~r/\A[a-z_][a-z0-9_]*\z/

  @admit """
  SELECT admission_id, effect_id, epoch, claim_version, version, source_seq,
         source_hash, descriptor_digest, plan_digest, admitted_at, execution_deadline, disposition
    FROM agent_ops.admit_launch($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
  """

  @doc false
  @spec plan_digest(map()) :: {:ok, <<_::256>>} | {:error, :invalid_launch_admission_plan}
  def plan_digest(
        %{
          effect_id: effect,
          intent_event_id: intent,
          run_id: run_id,
          chapter_id: chapter,
          tenant_id: tenant,
          project_id: project,
          execution_profile_id: profile_id,
          execution_profile_digest: profile_digest,
          adapter: adapter,
          profile:
            %{id: profile_id, approved: true, adapter: adapter, manifest: manifest} = profile,
          execution: %{run_id: run_id, ticket: ticket} = execution,
          requirements: requirements
        } = plan
      )
      when map_size(plan) == 12 and map_size(profile) == 4 and map_size(execution) == 2 and
             is_atom(adapter) and not is_nil(adapter) do
    # Reject opaque extra fields instead of silently omitting them from the
    # binding. This canonical value is hashed, never persisted or logged.
    payload = %{
      "schema" => "bizkit.agent-launch-admission-plan.v1",
      "effect_id" => effect,
      "intent_event_id" => intent,
      "run_id" => run_id,
      "chapter_id" => chapter,
      "tenant_id" => tenant,
      "project_id" => project,
      "execution_profile_id" => profile_id,
      "execution_profile_digest" => profile_digest,
      "adapter_module" => Atom.to_string(adapter),
      "execution" => %{"run_id" => run_id, "ticket" => ticket},
      "profile" => %{
        "id" => profile_id,
        "approved" => true,
        "adapter_module" => Atom.to_string(adapter),
        "manifest" => manifest
      },
      "requirements" => requirements
    }

    case Canonical.hash(payload) do
      {:ok, digest} -> {:ok, digest}
      _ -> {:error, :invalid_launch_admission_plan}
    end
  end

  def plan_digest(_), do: {:error, :invalid_launch_admission_plan}

  @doc false
  def run(context, head, gate, request) do
    with :ok <- context(context),
         :ok <- request(request),
         :ok <- head(head),
         {:ok, conn, schema} <- configured_store() do
      # Own the bounded checkout on the actual canonical pool. No backend call,
      # caller transaction or externally supplied callback runs under its locks.
      Postgrex.transaction(
        conn,
        fn tx -> admit(tx, schema, head, gate, request) end,
        timeout: @timeout
      )
    end
  rescue
    _ -> {:error, :agent_launch_admission_unavailable}
  catch
    _, _ -> {:error, :agent_launch_admission_unavailable}
  end

  defp context(%{environment: :staging} = context) when map_size(context) == 1, do: :ok

  defp context(%{environment: _} = context) when map_size(context) == 1,
    do: {:error, :staging_only}

  defp context(_), do: {:error, :invalid_launch_admission_context}

  defp request(
         %{
           run_key: {chapter, tenant, project, run},
           grants: grants,
           registry: registry,
           requirements: requirements,
           plan: plan,
           lease: %{version: version, epoch: epoch, token: token} = lease
         } = request
       )
       when map_size(request) == 6 and is_binary(chapter) and is_binary(tenant) and
              is_binary(project) and is_binary(run) and is_map(grants) and is_map(registry) and
              is_map(requirements) and is_map(plan) and map_size(lease) == 3 and
              is_integer(version) and version > 0 and is_integer(epoch) and epoch > 0 and
              is_binary(token) and byte_size(token) == 32,
       do: :ok

  defp request(_), do: {:error, :invalid_launch_admission_request}

  defp head(%{global_seq: seq, global_hash: hash})
       when is_integer(seq) and seq > 0 and is_binary(hash) and byte_size(hash) == 32,
       do: :ok

  defp head(_), do: {:error, :unverified_launch_source}

  defp configured_store do
    # EventStore append/read use this same cached running-store configuration.
    # EventStore.config/0 reparses Application env and is NOT this authority.
    config = EventStore.Config.lookup(CoopSubstrate.EventStore)
    schema = Keyword.get(config, :schema, "public")
    conn = Keyword.fetch!(config, :conn)

    if (is_pid(conn) or (is_atom(conn) and not is_nil(conn))) and
         is_binary(schema) and Regex.match?(@schema, schema),
       do: {:ok, conn, schema},
       else: {:error, :invalid_launch_source_schema}
  end

  defp admit(tx, schema, head, gate, request) do
    Postgrex.query!(
      tx,
      "SELECT set_config('lock_timeout', '2000ms', true), " <>
        "set_config('statement_timeout', '4000ms', true)",
      [],
      timeout: @timeout
    )

    with :ok <- lock_source(tx, schema, head),
         {:ok, run} <- AgentRuns.authorized?(gate.orchestration, request.run_key, request.grants),
         {:ok, plan} <-
           Preflight.prepare(run, request.registry, &Canonical.hash!/1, request.requirements),
         :ok <- RecoveryPort.check(plan.adapter, plan.profile),
         true <- plan === request.plan or {:error, :agent_launch_plan_changed},
         {:ok, digest} <- Attempts.descriptor_digest(plan),
         {:ok, plan_digest} <- plan_digest(plan),
         {:ok, receipt} <- persist_admission(tx, head, plan, digest, plan_digest, request) do
      receipt
    else
      {:error, reason} -> Postgrex.rollback(tx, reason)
      _ -> Postgrex.rollback(tx, :agent_launch_admission_refused)
    end
  end

  defp lock_source(tx, schema, head) do
    # EventStore's append updates this SAME stream row. No lock on an unrelated
    # projection or advisory name could order all canonical appenders.
    with {:ok, %{rows: [[stream, version]]}} <-
           Postgrex.query(
             tx,
             "SELECT stream_id, stream_version FROM #{schema}.streams " <>
               "WHERE stream_uuid = 'ledger' AND deleted_at IS NULL FOR UPDATE",
             [],
             timeout: @timeout
           ),
         true <- version == head.global_seq,
         {:ok, %{rows: [[bytes]]}} <-
           Postgrex.query(
             tx,
             "SELECT e.data FROM #{schema}.events e " <>
               "JOIN #{schema}.stream_events se ON se.event_id = e.event_id " <>
               "WHERE se.stream_id = $1 AND se.stream_version = $2",
             [stream, version],
             timeout: @timeout
           ),
         true <- :crypto.hash(:sha256, bytes) == head.global_hash do
      :ok
    else
      _ -> {:error, :unverified_launch_source}
    end
  end

  defp persist_admission(tx, head, plan, digest, plan_digest, request) do
    id = "agent-admission:" <> Base.encode16(:crypto.hash(:sha256, plan.effect_id), case: :lower)
    lease = request.lease

    params = [
      plan.effect_id,
      lease.version,
      lease.epoch,
      :crypto.hash(:sha256, lease.token),
      digest,
      id,
      head.global_seq,
      head.global_hash,
      request.grants.read,
      request.grants.execute,
      plan_digest
    ]

    case Postgrex.query(tx, @admit, params, timeout: @timeout) do
      {:ok,
       %{
         rows: [
           [
             ^id,
             effect,
             epoch,
             claim_version,
             version,
             seq,
             hash,
             ^digest,
             ^plan_digest,
             admitted_at,
             deadline,
             disposition
           ]
         ]
       }}
      when effect == plan.effect_id and epoch == lease.epoch and
             claim_version == lease.version and is_integer(version) and
             version == claim_version + 1 and is_integer(seq) and seq > 0 and
             seq <= head.global_seq and is_binary(hash) and byte_size(hash) == 32 and
             is_struct(admitted_at, DateTime) and is_struct(deadline, DateTime) and
             disposition in ["admitted", "existing"] ->
        {:ok,
         %{
           admission_id: id,
           effect_id: effect,
           epoch: epoch,
           claim_version: claim_version,
           version: version,
           source_seq: seq,
           source_hash: hash,
           descriptor_digest: digest,
           plan_digest: plan_digest,
           admitted_at: admitted_at,
           execution_deadline: deadline,
           disposition: if(disposition == "admitted", do: :admitted, else: :existing)
         }}

      _ ->
        {:error, :agent_launch_admission_refused}
    end
  end
end
