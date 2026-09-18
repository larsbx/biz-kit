defmodule DispatchWeb.Router do
  @moduledoc """
  Route table.

  The `/v1` machine API of Section 24 and the health surface of Section 32 are
  published here. The `/ui` portal, `/providers` webhooks, and break-glass
  routes are added by the slices that implement their authorization.

  Section 24.5 keeps `/v1` and `/ui` separate deliberately: `/v1` is JSON for
  machines and `/ui` is HTML or Datastar SSE for the portal. They are different
  pipelines, not different content negotiation on one.
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

  # Section 23.2 separates authentication from authorization, and the pipeline
  # mirrors that: `Authenticate` establishes who is calling, `ResolveActor`
  # selects the single role assignment they act under (Section 24.6), and the
  # Ash policies behind each action decide what that assignment permits. No step
  # can stand in for the next.
  pipeline :api do
    plug :accepts, ["json"]
    plug :put_no_store
    plug DispatchWeb.Plugs.Authenticate
    plug DispatchWeb.Plugs.ResolveActor
  end

  scope "/health", DispatchWeb do
    pipe_through :health

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/v1", DispatchWeb do
    pipe_through :api

    # Section 24.1: the canonical self-service route and the DRIVER
    # compatibility projection. Both reach the same controller function.
    post "/me/status-events", StatusEventController, :create
    post "/driver/status-events", StatusEventController, :create_driver
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
