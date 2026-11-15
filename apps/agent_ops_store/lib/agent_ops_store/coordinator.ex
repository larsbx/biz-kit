defmodule AgentOpsStore.Coordinator do
  @moduledoc """
  Explicit staging-only bridge from fresh signed TaskCore replay to PostgreSQL
  outbox attempts and an approved execution adapter. No supervisor or production
  endpoint is installed. The database is biz-kit's existing governed database.

  The trusted host supplies context/1, committed_state/0, environment/0,
  consent/1, reference/2 and request_termination/2.
  context returns current committed state, independent grant IDs, the approved
  registry, canonical hash function and trusted classification requirements.
  reference normalizes an adapter handle to a non-secret immutable locator.
  The host and all these ports remain inaccessible to executors.

  Repeated complete ledger scans can enqueue the same intents safely; the
  stable signed event effect ID and SQL uniqueness are the checkpoint. A crash
  during the scan simply repeats it. No business ledger is written here.
  Leases survive crashes, but recovery is fail-closed: uncertain executions
  remain blocked until independent backend reconciliation is implemented.
  """

  alias AgentCore.{Preflight, Profiles, RecoveryPort}
  alias AgentOpsStore.Postgres
  alias TaskCore.{AgentRuns, Dispatcher, ExecutionRecovery}

  @doc "Replay-derived complete scan; retrying a partial scan is idempotent."
  def enqueue_all(conn, host) do
    with :ok <- staging(host),
         {:ok, state} <- host.committed_state() do
      results =
        state.agent_runs
        |> Map.keys()
        |> Enum.sort()
        |> Enum.map(fn key -> {key, enqueue(conn, key, host)} end)

      {:ok, results}
    end
  end

  def enqueue(conn, key, host) do
    with :ok <- staging(host), do: Dispatcher.enqueue(key, ports(conn, host, "enqueue"))
  end

  def deliver(conn, key, host, owner) do
    with :ok <- staging(host), do: Dispatcher.deliver(key, ports(conn, host, owner))
  end

  @doc "Fence withdrawn authority and request termination; never infer confirmed cancellation."
  def withdraw(conn, key, host) do
    with :ok <- staging(host),
         {:ok, context} <- host.context(key),
         {:ok, run} <- Map.fetch(context.state.agent_runs, key),
         {:error, _reason} <- prepare(key, host),
         effect = "agent-run:" <> run.intent_event_id,
         {:ok, row} <- Postgres.snapshot(conn, effect),
         true <- row.run_key == key or {:error, :effect_scope_mismatch},
         :ok <- fence_withdrawal(conn, effect, row) do
      # The host resolves immutable historical backend identity, even when a
      # profile or its execution grant has since been revoked. A successful
      # request is deliberately NOT a termination receipt.
      case host.request_termination(effect, row.backend_ref) do
        :ok -> {:ok, :cancel_requested}
        _ -> {:error, :cancellation_requires_reconciliation}
      end
    else
      {:ok, _authorized_run} -> {:error, :run_authority_still_active}
      :error -> {:error, :unknown_agent_run}
      {:error, _} = error -> error
    end
  end

  defp fence_withdrawal(_conn, _effect, %{phase: "cancel_requested"}), do: :ok
  defp fence_withdrawal(_conn, _effect, %{phase: "cancelled"}), do: {:error, :already_cancelled}

  defp fence_withdrawal(conn, effect, row) do
    case Postgres.request_cancel(conn, effect, row.version) do
      {:ok, _version} -> :ok
      {:error, _} = error -> error
    end
  end

  defp staging(host) do
    if host.environment() == :staging, do: :ok, else: {:error, :staging_only}
  end

  @doc false
  def prepare(key, host) do
    with {:ok, plan, _context} <- authorized_context(key, host), do: {:ok, plan}
  end

  @doc false
  def authorized_context(key, host) do
    with :ok <- staging(host),
         {:ok, context} <- host.context(key),
         {:ok, run} <- AgentRuns.authorized?(context.state, key, context.grants),
         {:ok, plan} <-
           Preflight.prepare(run, context.registry, context.hash_manifest, context.requirements),
         :ok <- RecoveryPort.check(plan.adapter, plan.profile),
         :ok <- host.consent(plan) do
      {:ok, plan, context}
    end
  end

  defp ports(conn, host, owner) do
    %{
      prepare: &prepare(&1, host),
      register: &Postgres.register(conn, &1),
      snapshot: &Postgres.snapshot(conn, &1),
      claim: &Postgres.claim(conn, &1, &2, owner, 5_000, 2),
      validate_lease: &Postgres.validate_launch_lease(conn, &1, &2),
      request_cancel: &Postgres.request_cancel(conn, &1, &2),
      attach: fn effect, lease, reference ->
        Postgres.attach_backend(conn, effect, lease.version, lease.epoch, lease.token, reference)
      end,
      launch: fn plan ->
        with {:ok, handle} <- plan.adapter.launch(plan.execution, plan.profile, plan.effect_id),
             {:ok, reference} <- host.reference(plan, handle) do
          {:ok, reference}
        end
      end
    }
  end

  @doc "Recover by stable effect identity, including a crash before handle attachment."
  def recover(conn, key, host, owner) do
    with :ok <- staging(host),
         {:ok, context} <- host.context(key),
         {:ok, run} <- Map.fetch(context.state.agent_runs, key),
         {:ok, row} <- Postgres.snapshot(conn, "agent-run:" <> run.intent_event_id),
         true <- row.run_key == key or {:error, :effect_scope_mismatch} do
      authority = prepare(key, host)

      with {:ok, row} <- fence_if_withdrawn(conn, row, authority),
           {:ok, cleanup} <- host.recovery_context(row),
           {:ok, profile} <- Profiles.resolve(row, cleanup.registry, cleanup.hash_manifest),
           :ok <- RecoveryPort.check(profile.adapter, profile),
           {:ok, raw} <- profile.adapter.lookup(profile, row.effect_id),
           {:ok, observation} <- host.verify_observation(row, raw),
           {:ok, action} <- ExecutionRecovery.decide(row, observation) do
        case action do
          :request_termination ->
            with :ok <- fence_withdrawal(conn, row.effect_id, row),
                 :ok <- host.request_termination(row.effect_id, observation[:backend_ref]) do
              {:ok, :cancel_requested}
            end

          :confirm_cancel ->
            Postgres.apply_recovery(conn, row, observation, owner)

          _ ->
            # Current grants, profile approval, consent and task version must
            # still match AFTER the external lookup/proof verification wait.
            with {:ok, plan} <- authority,
                 {:ok, ^plan} <- prepare(key, host),
                 {:ok, :existing} <- Postgres.register(conn, plan) do
              Postgres.apply_recovery(conn, row, observation, owner)
            end
        end
      end
    else
      :error -> {:error, :unknown_agent_run}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :backend_reconciliation_unavailable}
  catch
    :exit, _ -> {:error, :backend_reconciliation_unavailable}
  end

  defp fence_if_withdrawn(_conn, row, {:ok, _plan}), do: {:ok, row}

  defp fence_if_withdrawn(conn, row, {:error, _reason}) do
    with :ok <- fence_withdrawal(conn, row.effect_id, row),
         do: Postgres.snapshot(conn, row.effect_id)
  end

  @doc "Accept bounded bytes from a trusted runner, never agent-supplied lease material."
  def submit_candidate(conn, key, host, lease, bytes) when is_binary(bytes) do
    with :ok <- staging(host),
         {:ok, plan} <- prepare(key, host),
         {:ok, :existing} <- Postgres.register(conn, plan),
         true <-
           byte_size(bytes) <= plan.requirements["max_output_bytes"] or
             {:error, :candidate_too_large_or_invalid} do
      Postgres.commit_candidate(
        conn,
        plan.effect_id,
        lease.version,
        lease.epoch,
        lease.token,
        bytes
      )
    end
  end

  def submit_candidate(_conn, _key, _host, _lease, _bytes),
    do: {:error, :candidate_too_large_or_invalid}

  @doc "Freshly authorized candidate retrieval; returned bytes remain non-authoritative."
  def candidate(conn, key, host) do
    with {:ok, plan} <- prepare(key, host),
         {:ok, :existing} <- Postgres.register(conn, plan),
         do: Postgres.candidate(conn, plan)
  end

  @doc "Host-only renewal with current authorization and an unchanged execution budget."
  def renew(conn, key, host, lease) do
    with {:ok, plan} <- prepare(key, host),
         {:ok, :existing} <- Postgres.register(conn, plan),
         do: Postgres.renew(conn, plan.effect_id, lease.version, lease.epoch, lease.token, 5_000)
  end

  @doc "Explicit staging worker tick; the return value never includes lease tokens or result bytes."
  def tick(conn, host, owner) do
    with :ok <- staging(host),
         {:ok, state} <- host.committed_state() do
      results =
        state.agent_runs
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {key, run} ->
          result = tick_effect(conn, key, "agent-run:" <> run.intent_event_id, host, owner)
          {key, summarize(result)}
        end)

      {:ok, results}
    end
  end

  defp tick_effect(conn, key, effect, host, owner) do
    case Postgres.snapshot(conn, effect) do
      {:error, :unknown_agent_effect} ->
        deliver(conn, key, host, owner)

      {:ok, %{run_key: stored}} when stored != key ->
        {:error, :effect_scope_mismatch}

      {:ok, %{phase: "pending"}} ->
        case prepare(key, host) do
          {:ok, _plan} -> deliver(conn, key, host, owner)
          {:error, _} -> withdraw(conn, key, host)
        end

      {:ok, %{phase: "cancelled"}} ->
        {:ok, :cancelled}

      {:ok, %{phase: "cancel_requested"}} ->
        recover(conn, key, host, owner)

      {:ok, %{phase: "leased", expired: true}} ->
        recover(conn, key, host, owner)

      {:ok, row} ->
        case prepare(key, host) do
          {:ok, _plan} -> {:ok, row.phase}
          {:error, _} -> withdraw(conn, key, host)
        end

      {:error, _} = error ->
        error
    end
  end

  defp summarize({:ok, %{disposition: disposition}}), do: {:ok, disposition}
  defp summarize({:ok, %{phase: phase}}), do: {:ok, phase}
  defp summarize({:ok, value}) when is_atom(value) or is_binary(value), do: {:ok, value}
  defp summarize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp summarize(_other), do: {:error, :execution_tick_failed}
end
