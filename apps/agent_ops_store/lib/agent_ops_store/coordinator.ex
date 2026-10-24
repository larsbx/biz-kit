defmodule AgentOpsStore.Coordinator do
  @moduledoc """
  Explicit staging-only bridge from fresh signed TaskCore replay to PostgreSQL
  outbox attempts and an approved execution adapter. No supervisor or production
  endpoint is installed. The database is biz-kit's existing governed database.

  The trusted host supplies context/1, environment/0, consent/1 and reference/2.
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

  alias AgentCore.Preflight
  alias AgentOpsStore.Postgres
  alias TaskCore.{AgentRuns, Dispatcher}

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

  defp staging(host) do
    if host.environment() == :staging, do: :ok, else: {:error, :staging_only}
  end

  defp prepare(key, host) do
    with {:ok, context} <- host.context(key),
         {:ok, run} <- AgentRuns.authorized?(context.state, key, context.grants),
         {:ok, plan} <-
           Preflight.prepare(run, context.registry, context.hash_manifest, context.requirements),
         :ok <- host.consent(plan) do
      {:ok, plan}
    end
  end

  defp ports(conn, host, owner) do
    %{
      prepare: &prepare(&1, host),
      register: &Postgres.register(conn, &1),
      snapshot: &Postgres.snapshot(conn, &1),
      claim: &Postgres.claim(conn, &1, &2, owner, 60_000, 1),
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
end
