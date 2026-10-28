defmodule AgentOpsStore.Worker do
  @moduledoc """
  Opt-in staging child specification. It is never added to production startup.
  The supplied host must implement immutable-effect lookup verification and
  fresh committed execution context. DB connections remain host-only.
  """

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    host = Keyword.fetch!(opts, :host)

    if host.environment() == :staging do
      conn = Keyword.fetch!(opts, :connection)
      owner = Keyword.fetch!(opts, :owner)

      TaskCore.ExecutionWorker.start_link(
        opts
        |> Keyword.take([:name, :interval_ms, :timeout_ms])
        |> Keyword.put(:tick, fn -> AgentOpsStore.Coordinator.tick(conn, host, owner) end)
      )
    else
      {:error, :staging_only}
    end
  end
end
