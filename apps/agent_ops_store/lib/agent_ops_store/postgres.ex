defmodule AgentOpsStore.Postgres do
  @moduledoc """
  Low-level transactional PostgreSQL adapter for AgentCore operational attempts.

  **Not a coordinator or authorization service.** Only a trusted host may
  invoke this module after current signed TaskCore intent, agent/task read
  grants, tenant, consent, and approved execution profile are checked.

  PostgreSQL is the operational persistence mechanism inside the SAME
  governed biz-kit database. The signed CoopSubstrate ledger remains the
  business authority. This module neither launches an agent nor appends a
  business event, and it never sends a plaintext lease token to the database.

  Precondition: reviewed migrations 001_agent_attempts.sql and
  002_attempt_cas.sql have been applied; the database role has narrowly
  granted USAGE/SELECT/INSERT and EXECUTE rights. Never pass this connection
  to a sandbox or expose these functions as unauthenticated tools.

  Optimistic row_version and generation fencing are enforced by the SQL
  functions, not by application-side read-modify-write cycles. Zero rows means
  the operation was refused (including stale/revoked attempt). Expired leases
  are not reusable without separately verified reconciliation.
  """

  alias AgentCore.Attempts

  @select_digest "SELECT descriptor_digest FROM agent_ops.execution_attempts WHERE effect_id = $1"

  @insert """
  INSERT INTO agent_ops.execution_attempts (
    effect_id, intent_event_id, chapter_id, tenant_id, project_id, run_id,
    task_id, task_version, task_source_event_id, definition_digest,
    execution_profile_id, execution_profile_digest, max_duration_ms,
    max_output_bytes, descriptor_digest
  ) VALUES (
    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15
  )
  ON CONFLICT (effect_id) DO NOTHING
  RETURNING effect_id
  """

  @doc """
  Persist a previously authorized and preflight-validated effect descriptor.

  The BEAM-local descriptor checksum is an *operational collision check*,
  not a canonical ledger signature. A canonical signed run must already
  exist independently. No task content or credentials are stored here.
  """
  @spec register(pid() | atom(), map()) ::
          {:ok, :new | :existing} | {:error, atom()}
  def register(conn, plan) do
    with {:ok, %{records: records}, :new} <- Attempts.register(Attempts.init(), plan) do
      %{descriptor: d} = Map.fetch!(records, plan.effect_id)
      effect_id = d.effect_id
      digest = descriptor_digest(d)

      params = [
        d.effect_id,
        d.intent_event_id,
        d.chapter_id,
        d.tenant_id,
        d.project_id,
        d.run_id,
        d.task_id,
        d.task_version,
        d.task_source_event_id,
        Base.decode16!(d.definition_digest, case: :lower),
        d.execution_profile_id,
        elem(d.execution_profile_digest, 1),
        d.max_duration_ms,
        d.max_output_bytes,
        digest
      ]

      case query(conn, @insert, params) do
        {:ok, [[^effect_id]]} ->
          {:ok, :new}

        {:ok, []} ->
          compare_existing(conn, d.effect_id, digest)

        {:error, _} ->
          {:error, :operational_db_unavailable}
      end
    end
  end

  @doc """
  Generate a fresh 256-bit lease token; only its digest is persisted.

  The coordinator must atomically durably record this claim before dispatch,
  and pass the SAME signed effect ID to the selected backend for idempotency.
  The token must never appear in prompts, logs, task events or agent records.
  """
  @spec claim(pid() | atom(), String.t(), pos_integer(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, %{epoch: pos_integer(), version: pos_integer(), token: binary()}}
          | {:error, atom()}
  def claim(conn, effect_id, version, owner, lease_ms, attempt_limit) do
    token = :crypto.strong_rand_bytes(32)

    with {:ok, [[epoch, next_version]]} <-
           query(
             conn,
             "SELECT epoch, version FROM agent_ops.claim_attempt($1,$2,$3,$4,$5,$6)",
             [effect_id, version, owner, hash(token), lease_ms, attempt_limit]
           ) do
      {:ok, %{epoch: epoch, version: next_version, token: token}}
    else
      {:ok, []} -> {:error, :claim_refused}
      {:error, _} -> {:error, :operational_db_unavailable}
    end
  end

  @doc "Lease renewal is refused for wrong token, epoch, version or expiry."
  def renew(conn, effect_id, version, epoch, token, lease_ms) do
    invoke(conn, "renew_attempt", [effect_id, version, epoch, hash_token(token), lease_ms], 5)
  end

  @doc "Attach one immutable backend locator to a current live attempt."
  def attach_backend(conn, effect_id, version, epoch, token, backend_ref) do
    invoke(conn, "attach_backend", [effect_id, version, epoch, hash_token(token), backend_ref], 5)
  end

  @doc "Candidate digest only; completion and evidence are separately authorized."
  def record_candidate(conn, effect_id, version, epoch, token, {:bytes, <<_::256>>} = digest) do
    invoke(
      conn,
      "record_candidate",
      [effect_id, version, epoch, hash_token(token), elem(digest, 1)],
      5
    )
  end

  def record_candidate(_conn, _effect_id, _version, _epoch, _token, _digest),
    do: {:error, :invalid_candidate_digest}

  @doc "Request cancellation only after signed ledger cancellation admission."
  def request_cancel(conn, effect_id, version),
    do: invoke(conn, "request_cancel", [effect_id, version], 2)

  @doc "Host must verify termination receipt before invoking this primitive."
  def confirm_cancel_preverified(conn, effect_id, version, receipt),
    do: invoke(conn, "confirm_cancel_preverified", [effect_id, version, receipt], 3)

  @doc """
  Host must verify backend absence against immutable effect/backend identities
  *before* this call. An arbitrary receipt string conveys NO such proof.
  """
  def reconcile_absent_preverified(conn, effect_id, version, epoch, receipt),
    do: invoke(conn, "reconcile_absent_preverified", [effect_id, version, epoch, receipt], 4)

  @doc "Operational row snapshot, with sensitive lease token digest excluded."
  def snapshot(conn, effect_id) do
    statement = """
    SELECT phase, attempt_epoch, attempts, row_version, backend_ref,
           candidate_digest, reconciliation_receipt_id, cancellation_receipt_id
      FROM agent_ops.execution_attempts WHERE effect_id=$1
    """

    case query(conn, statement, [effect_id]) do
      {:ok, [[phase, epoch, attempts, version, backend, digest, reconciliation, cancellation]]} ->
        {:ok,
         %{
           phase: phase,
           epoch: epoch,
           attempts: attempts,
           version: version,
           backend_ref: backend,
           candidate_digest: digest,
           reconciliation_receipt_id: reconciliation,
           cancellation_receipt_id: cancellation
         }}

      {:ok, []} ->
        {:error, :unknown_agent_effect}

      {:error, _} ->
        {:error, :operational_db_unavailable}
    end
  end

  defp compare_existing(conn, effect_id, digest) do
    case query(conn, @select_digest, [effect_id]) do
      {:ok, [[^digest]]} -> {:ok, :existing}
      {:ok, [[_different]]} -> {:error, :agent_effect_conflict}
      {:ok, []} -> {:error, :operational_register_race}
      {:error, _} -> {:error, :operational_db_unavailable}
    end
  end

  defp invoke(conn, name, args, count) do
    params = Enum.map_join(1..count, ",", &"$#{&1}")

    case query(conn, "SELECT version FROM agent_ops.#{name}(#{params})", args) do
      {:ok, [[version]]} -> {:ok, version}
      {:ok, []} -> {:error, :transition_refused}
      {:error, _} -> {:error, :operational_db_unavailable}
    end
  end

  defp query(conn, sql, params) do
    case Postgrex.query(conn, sql, params) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, rows}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :query_failed}
  end

  defp descriptor_digest(descriptor),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(descriptor))

  defp hash_token(token) when is_binary(token) and byte_size(token) == 32, do: hash(token)
  defp hash_token(_invalid), do: <<0>>

  defp hash(token), do: :crypto.hash(:sha256, token)
end
