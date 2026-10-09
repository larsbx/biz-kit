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

  # Passed through Phoenix's own `put_secure_browser_headers` rather than set by
  # hand. Writing the headers directly worked and cost the framework's baseline —
  # and a scanner reading the pipeline could not tell a deliberate set from a
  # forgotten one, which is a fair complaint: the next person adding a pipeline
  # has the same trouble.
  #
  # Section 26.1 prohibits inline scripts, which is what makes the absence of
  # `unsafe-inline` here load-bearing rather than tidy, and Section 24.7 wants
  # `no-referrer` rather than the framework's cross-origin default.
  @portal_headers %{
    "content-security-policy" =>
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " <>
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    "referrer-policy" => "no-referrer",
    # The framework defaults this to SAMEORIGIN, which would disagree with the
    # `frame-ancestors 'none'` above. Modern browsers take the CSP and ignore
    # this header, so the disagreement is invisible until one does not — and a
    # reader comparing the two has no way to tell which was intended.
    "x-frame-options" => "DENY"
  }

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

  # Section 26.1: scripts from this origin only, and no inline scripts. The
  # Datastar bundle is served from `priv/static/vendor`, so `self` is the whole
  # allowance a first-release portal needs; Section 28.5's map adapter is what
  # will widen it, and Section 26.1 requires that widening to be a CSP change
  # with a test rather than an edit to a page template.
  pipeline :portal do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @portal_headers
    plug :put_no_store
    plug DispatchWeb.Plugs.PortalSession
  end

  # Sign-in and role selection cannot require a resolved actor: they are how one
  # is obtained. Same headers and CSRF protection, no actor.
  pipeline :portal_public do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @portal_headers
    plug :put_no_store
  end

  scope "/", DispatchWeb do
    pipe_through :portal_public

    get "/login", SessionController, :login
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete
  end

  # Role selection sits between the two: it needs an authenticated subject and
  # must *not* require a resolved actor, because choosing one is what it is for.
  # Guarding it with `PortalSession` sends exactly the multi-assignment users who
  # need the switcher into a redirect loop — and only them, so a suite built on
  # single-assignment fixtures never meets it.
  pipeline :portal_choosing do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @portal_headers
    plug :put_no_store
    plug DispatchWeb.Plugs.RequireSubject
  end

  scope "/", DispatchWeb do
    pipe_through :portal_choosing

    get "/select-role", SessionController, :select_role
    post "/select-role", SessionController, :choose_role
  end

  scope "/", DispatchWeb do
    pipe_through :portal

    # Section 24.5's live endpoints. Same pipeline as the pages they patch,
    # because a stream is not a lesser surface: it carries the same fragments to
    # the same viewer and must be authorized the same way.
    get "/ui/operations/stream", StreamController, :operations
    get "/ui/participants/:participant_id/stream", StreamController, :participant

    # Section 4.3's primary routes. Section 26.2 fixes the paths.
    get "/operations", PortalController, :operations
    get "/partner/stops/:stop_id", PortalController, :partner_stop
    get "/operations/participants/:participant_id", PortalController, :operations_participant
    get "/operations/drivers/:driver_id", PortalController, :operations_driver
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
