defmodule AgentCore.Attempts do
  @moduledoc """
  Pure operational lease and recovery rules for engine-neutral agent attempts.

  This is NOT a GenServer, queue, database, scheduler, or business authority.
  A trusted coordinating host must persist the returned state durably, apply
  each transition under a serialized compare-and-swap transaction, and recover
  it after restart. The host MUST check fresh ledger intent, read/run grants
  and profile approval before enqueue, claim, tools and result admission.

  A stable effect ID is derived from the signed run-intent event ID. Lease
  epochs fence out late heartbeats/results. An expired lease is NOT an
  automatic retry: the host must first reconcile the backend's execution
  status and idempotency key, because a timed-out worker may still be active.

  Results recorded here are non-authoritative *candidates*. Business writes,
  custody, DoD approval and execution cancellation still require their own
  authorization and independently verified evidence.
  """

  @max_lease_ms 300_000
  @max_attempts 10
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/

  @doc "An empty operational projection, not a second business event log."
  def init, do: %{records: %{}}

  @doc """
  Idempotently register a *trusted, authorized* engine-neutral preflight.
  Only stable identifiers and profile digest are retained; no prompt, secret,
  task contents, worker module or runtime handle enters this projection.
  """
  @spec register(map(), map()) :: {:ok, map(), :new | :existing} | {:error, atom()}
  def register(%{records: records} = state, plan) when is_map(records) and is_map(plan) do
    with {:ok, descriptor} <- descriptor(plan) do
      case Map.get(records, plan.effect_id) do
        nil ->
          row = %{
            descriptor: descriptor,
            phase: :pending,
            epoch: 0,
            attempts: 0,
            lease: nil,
            candidate_digest: nil,
            backend_ref: nil,
            cancel_receipt: nil,
            reconciliation_receipt: nil
          }

          {:ok, put_in(state, [:records, plan.effect_id], row), :new}

        %{descriptor: ^descriptor} ->
          {:ok, state, :existing}

        _ ->
          {:error, :agent_effect_conflict}
      end
    end
  end

  def register(_state, _plan), do: {:error, :invalid_operational_projection}

  @doc """
  Claim a pending attempt with a host-generated owner and unpredictable token.

  The host must atomically persist the new epoch BEFORE launching a backend.
  The same effect_id must be passed to the backend for idempotent launch.
  A lease grants no business authority.
  """
  @spec claim(map(), String.t(), String.t(), String.t(), integer(), integer(), integer()) ::
          {:ok, map(), map()} | {:error, atom()}
  def claim(state, effect_id, owner, token, now_ms, lease_ms, max_attempts) do
    with :ok <- claim_fields(effect_id, owner, token, now_ms, lease_ms, max_attempts),
         {:ok, row} <- fetch(state, effect_id),
         :ok <- claimable(row, max_attempts) do
      lease = %{
        epoch: row.epoch + 1,
        owner: owner,
        token: token,
        expires_at_ms: now_ms + lease_ms
      }

      updated = %{
        row
        | phase: :leased,
          epoch: lease.epoch,
          attempts: row.attempts + 1,
          lease: lease,
          backend_ref: nil
      }
      {:ok, replace(state, effect_id, updated), lease}
    end
  end

  @doc """
  Bind a normalized backend execution reference to the current live lease.

  This is an operational locator, not a credential, authorization grant or
  proof of execution. The coordinator must also be able to recover by stable
  effect ID when launch succeeded but the reference could not be persisted.
  """
  @spec attach_backend(map(), String.t(), integer(), String.t(), integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def attach_backend(state, effect_id, epoch, token, now_ms, backend_ref) do
    with :ok <- clock(now_ms),
         true <- segment?(backend_ref) or {:error, :invalid_backend_reference},
         {:ok, row} <- fetch(state, effect_id),
         :ok <- active_lease(row, epoch, token, now_ms) do
      case row.backend_ref do
        nil ->
          {:ok, replace(state, effect_id, %{row | backend_ref: backend_ref})}

        ^backend_ref ->
          {:ok, state}

        _other ->
          {:error, :backend_reference_conflict}
      end
    end
  end

  @doc "Renew only the latest unexpired lease; stale epochs/tokens fail closed."
  @spec renew(map(), String.t(), integer(), String.t(), integer(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def renew(state, effect_id, epoch, token, now_ms, lease_ms) do
    with :ok <- clock(now_ms),
         :ok <- lease_length(lease_ms),
         {:ok, row} <- fetch(state, effect_id),
         :ok <- active_lease(row, epoch, token, now_ms) do
      new_until = max(row.lease.expires_at_ms, now_ms + lease_ms)
      updated = put_in(row, [:lease, :expires_at_ms], new_until)
      {:ok, replace(state, effect_id, updated)}
    end
  end

  @doc """
  Record only a bounded digest of a candidate from the current live lease.
  This never constitutes task evidence, accepted model claims, or completion.
  """
  @spec candidate(map(), String.t(), integer(), String.t(), integer(), tuple()) ::
          {:ok, map()} | {:error, atom()}
  def candidate(state, effect_id, epoch, token, now_ms, {:bytes, <<_::256>>} = digest) do
    with :ok <- clock(now_ms),
         {:ok, row} <- fetch(state, effect_id),
         :ok <- active_lease(row, epoch, token, now_ms) do
      updated = %{row | phase: :candidate_ready, lease: nil, candidate_digest: digest}
      {:ok, replace(state, effect_id, updated)}
    end
  end

  def candidate(_state, _id, _epoch, _token, _time, _digest),
    do: {:error, :invalid_candidate_digest}

  @doc """
  Request cancellation and fence every outstanding worker lease. The host
  must independently call the adapter's cancel/2 and verify termination.
  """
  @spec request_cancel(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def request_cancel(state, effect_id) do
    with {:ok, row} <- fetch(state, effect_id) do
      updated =
        case row.phase do
          :cancel_requested -> row
          :cancelled -> row
          _ -> %{row | phase: :cancel_requested, epoch: row.epoch + 1, lease: nil}
        end

      {:ok, replace(state, effect_id, updated)}
    end
  end

  @doc "A trusted host records termination only after backend reconciliation."
  @spec confirm_cancel(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def confirm_cancel(state, effect_id, receipt) do
    with true <- segment?(receipt) or {:error, :invalid_cancel_receipt},
         {:ok, row} <- fetch(state, effect_id) do
      case row.phase do
        :cancel_requested ->
          {:ok, replace(state, effect_id, %{row | phase: :cancelled, cancel_receipt: receipt})}

        :cancelled ->
          if row.cancel_receipt == receipt,
            do: {:ok, state},
            else: {:error, :cancel_receipt_conflict}

        _ ->
          {:error, :cancel_not_requested}
      end
    end
  end

  @doc """
  Reconcile a TIMED-OUT lease using a trusted backend observation.

  {:absent, receipt_id} means a trusted backend reconciler has independently
  PROVED that this effect ID has no running or committed execution, with a
  durable receipt that can be audited. The coordinator must validate the
  receipt's provenance and exact backend identity before calling this API.
  When backend state is unknown, refuse: time expiry never licenses another
  launch. A recovered candidate is still only a candidate digest.
  """
  @spec reconcile_timeout(
          map(),
          String.t(),
          integer(),
          {:absent, String.t()} | :unknown | {:candidate, tuple(), String.t()}
        ) :: {:ok, map()} | {:error, atom()}
  def reconcile_timeout(state, effect_id, now_ms, observation) do
    with :ok <- clock(now_ms),
         {:ok, row} <- fetch(state, effect_id),
         :ok <- expired_lease(row, now_ms) do
      case observation do
        {:absent, receipt} ->
          if segment?(receipt) do
            updated = %{
              row
              | phase: :pending,
                lease: nil,
                reconciliation_receipt: receipt
            }

            {:ok, replace(state, effect_id, updated)}
          else
            {:error, :invalid_reconciliation_receipt}
          end

        {:candidate, {:bytes, <<_::256>>} = digest, receipt} ->
          if segment?(receipt) do
            updated = %{
              row
              | phase: :candidate_ready,
                lease: nil,
                candidate_digest: digest,
                reconciliation_receipt: receipt
            }

            {:ok, replace(state, effect_id, updated)}
          else
            {:error, :invalid_reconciliation_receipt}
          end

        _ ->
          {:error, :backend_outcome_not_proven}
      end
    end
  end

  @doc "Read current operational state; callers still must authorize the read."
  def get(%{records: records}, effect_id) when is_map(records) do
    case Map.fetch(records, effect_id) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_agent_effect}
    end
  end

  def get(_state, _effect_id), do: {:error, :invalid_operational_projection}

  @ticket_keys ~w(chapter_id tenant_id project_id task_id task_version source_event_id definition_digest)

  defp descriptor(%{
         effect_id: effect,
         intent_event_id: intent,
         run_id: run_id,
         chapter_id: chapter,
         tenant_id: tenant,
         project_id: project,
         execution_profile_id: profile,
         execution_profile_digest: {:bytes, <<_::256>>} = digest,
         execution: %{run_id: execution_run_id, ticket: ticket},
         requirements: %{
           "max_duration_ms" => max_duration,
           "max_output_bytes" => max_output
         }
       }) do
    if Enum.all?([intent, run_id, chapter, tenant, project, profile], &segment?/1) and
         effect == "agent-run:" <> intent and execution_run_id == run_id and
         safe_ticket?(ticket, chapter, tenant, project) and
         positive_integer?(max_duration) and positive_integer?(max_output) do
      {:ok,
       %{
         effect_id: effect,
         intent_event_id: intent,
         run_id: run_id,
         chapter_id: chapter,
         tenant_id: tenant,
         project_id: project,
         execution_profile_id: profile,
         execution_profile_digest: digest,
         task_id: ticket["task_id"],
         task_version: ticket["task_version"],
         task_source_event_id: ticket["source_event_id"],
         definition_digest: ticket["definition_digest"],
         max_duration_ms: max_duration,
         max_output_bytes: max_output
       }}
    else
      {:error, :invalid_agent_effect_descriptor}
    end
  end

  defp descriptor(_), do: {:error, :invalid_agent_effect_descriptor}

  defp safe_ticket?(ticket, chapter, tenant, project) when is_map(ticket) do
    Enum.sort(Map.keys(ticket)) == Enum.sort(@ticket_keys) and
      ticket["chapter_id"] == chapter and ticket["tenant_id"] == tenant and
      ticket["project_id"] == project and
      segment?(ticket["task_id"]) and segment?(ticket["source_event_id"]) and
      positive_integer?(ticket["task_version"]) and
      is_binary(ticket["definition_digest"]) and
      Regex.match?(~r/\\A[0-9a-f]{64}\\z/, ticket["definition_digest"])
  end

  defp safe_ticket?(_ticket, _chapter, _tenant, _project), do: false

  defp positive_integer?(v), do: is_integer(v) and v > 0

  defp claim_fields(effect_id, owner, token, now_ms, lease_ms, max_attempts) do
    if is_binary(effect_id) and String.starts_with?(effect_id, "agent-run:") and
         segment?(owner) and segment?(token) and clock(now_ms) == :ok and
         lease_length(lease_ms) == :ok and
         is_integer(max_attempts) and max_attempts in 1..@max_attempts,
       do: :ok,
       else: {:error, :invalid_lease_claim}
  end

  defp clock(value) when is_integer(value) and value >= 0, do: :ok
  defp clock(_value), do: {:error, :invalid_coordinator_time}

  defp lease_length(ms) when is_integer(ms) and ms in 1..@max_lease_ms, do: :ok
  defp lease_length(_ms), do: {:error, :invalid_lease_duration}

  defp claimable(%{phase: :pending, attempts: attempts}, maximum) do
    if attempts < maximum, do: :ok, else: {:error, :attempt_budget_exhausted}
  end

  defp claimable(%{phase: :leased}, _maximum),
    do: {:error, :lease_requires_reconciliation}

  defp claimable(%{phase: :cancel_requested}, _maximum), do: {:error, :cancel_requested}
  defp claimable(_row, _maximum), do: {:error, :agent_effect_not_claimable}

  defp active_lease(%{phase: :leased, lease: lease}, epoch, token, now_ms)
       when is_map(lease) do
    cond do
      not is_integer(epoch) or epoch != lease.epoch -> {:error, :stale_attempt_epoch}
      not is_binary(token) or token != lease.token -> {:error, :invalid_attempt_token}
      now_ms >= lease.expires_at_ms -> {:error, :lease_expired}
      true -> :ok
    end
  end

  defp active_lease(_row, _epoch, _token, _now_ms), do: {:error, :no_active_attempt}

  defp expired_lease(%{phase: :leased, lease: %{expires_at_ms: until}}, now_ms) do
    if now_ms >= until, do: :ok, else: {:error, :lease_not_expired}
  end

  defp expired_lease(_row, _now_ms), do: {:error, :no_expired_attempt}

  defp fetch(state, effect_id), do: get(state, effect_id)
  defp replace(state, effect_id, row), do: put_in(state, [:records, effect_id], row)
  defp segment?(value), do: is_binary(value) and Regex.match?(@segment, value)
end
