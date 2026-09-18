defmodule DispatchWeb.Router do
  @moduledoc """
  Route table. Slice 0 publishes only the health surface of Section 32; the
  `/v1`, `/ui`, `/providers`, and portal routes are added by the slices that
  implement their authorization.
  """

  use Phoenix.Router

  import Plug.Conn

  pipeline :health do
    plug :accepts, ["json"]
    plug :put_no_store
  end

  # Section 32 makes /health/dependencies an authenticated diagnostic endpoint.
  pipeline :diagnostic do
    plug :accepts, ["json"]
    plug :put_no_store
    plug DispatchWeb.Plugs.DiagnosticAuth
  end

  scope "/health", DispatchWeb do
    pipe_through :health

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/health", DispatchWeb do
    pipe_through :diagnostic

    get "/dependencies", HealthController, :dependencies
  end

  defp put_no_store(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
