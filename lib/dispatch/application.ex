defmodule Dispatch.Application do
  @moduledoc """
  The single supervised OTP release described in Section 21.1.

  Slice 0 starts only the infrastructure a readiness check can assert:
  telemetry, the PostgreSQL/PostGIS repository, and the Phoenix endpoint.
  Domain supervisors, the Oban queues of Section 21.3, and the agent-runtime
  port of Section 21.4 are introduced by the slices that own them.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # Section 31: fail closed before anything binds a port or opens a pool.
    Dispatch.Config.validate!()

    children = [
      Dispatch.Telemetry,
      Dispatch.Repo,
      {Phoenix.PubSub, name: Dispatch.PubSub},
      DispatchWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dispatch.Supervisor)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    DispatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
