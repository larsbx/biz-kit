defmodule AgentOpsStore.ToolProxy do
  @moduledoc """
  Staging-only typed task-read proxy. The authenticated identity is supplied by
  the trusted host's execution authentication boundary, NEVER by request JSON.
  It binds principal, effect, epoch and immutable backend reference. Executors
  receive neither DB credentials nor lease tokens. No business mutation tool
  or unrestricted dispatch/apply/shell path is exposed.
  """

  alias AgentOpsStore.{Coordinator, Postgres}
  alias TaskCore.ExecutionTools

  @doc "Transport entry point: authentication is independent of the tool body."
  def request(conn, host, credential, request) do
    with true <- host.environment() == :staging or {:error, :staging_only},
         {:ok, identity} <- host.authenticate_execution(credential) do
      call(conn, host, identity, request)
    end
  rescue
    _ -> {:error, :execution_authentication_unavailable}
  catch
    :exit, _ -> {:error, :execution_authentication_unavailable}
  end

  @doc false
  def call(conn, host, identity, %{name: "task.read", arguments: %{}} = request)
      when map_size(request) == 2 and is_map(identity) do
    with true <- map_size(request.arguments) == 0 or {:error, :invalid_tool_arguments},
         true <- host.environment() == :staging or {:error, :staging_only},
         {:ok, row} <- Postgres.snapshot(conn, identity[:effect_id]),
         :ok <- live_instance(row, identity),
         {:ok, plan, context} <- Coordinator.authorized_context(row.run_key, host),
         {:ok, :existing} <- Postgres.register(conn, plan),
         run = Map.fetch!(context.state.agent_runs, row.run_key),
         true <-
           run.agent_principal_id == identity[:principal_id] or
             {:error, :task_access_principal_mismatch},
         true <-
           "task_read_v1" in plan.requirements["features"] or
             {:error, :execution_tool_not_allowed},
         {:ok, latest} <- Postgres.snapshot(conn, identity.effect_id),
         :ok <- live_instance(latest, identity) do
      ticket = plan.execution.ticket

      ExecutionTools.read_task(context.state, identity.principal_id, %{
        chapter_id: ticket["chapter_id"],
        tenant_id: ticket["tenant_id"],
        project_id: ticket["project_id"],
        task_id: ticket["task_id"],
        task_version: ticket["task_version"],
        source_event_id: ticket["source_event_id"],
        principal_id: identity.principal_id,
        grant_event_id: context.grants.read,
        action: "read"
      })
    end
  end

  def call(_conn, _host, _identity, _request), do: {:error, :unknown_or_malformed_execution_tool}

  defp live_instance(row, identity) do
    if row.phase == "leased" and not row.expired and not row.deadline_expired and
         is_binary(row.backend_ref) and row.backend_ref == identity[:backend_ref] and
         row.epoch == identity[:epoch], do: :ok, else: {:error, :stale_execution_identity}
  end
end
