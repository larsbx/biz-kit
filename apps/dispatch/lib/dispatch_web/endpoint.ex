defmodule DispatchWeb.Endpoint do
  @moduledoc """
  HTTP entry point. Section 21.1 confines this layer to transport concerns:
  parsing, session handling, static assets, and response mapping.
  """

  use Phoenix.Endpoint, otp_app: :dispatch

  # Section 24.7 requires `no-store` on break-glass responses and Section 26.6
  # on map data. Those are set per-response; the session cookie below is the
  # encrypted server session that Section 24.6 revalidates on every request.
  @session_options [
    store: :cookie,
    key: "_dispatch_session",
    signing_salt: "5xJq0pQe",
    encryption_salt: "Nn4vT2kA",
    same_site: "Lax",
    http_only: true,
    secure: true,
    max_age: 60 * 60 * 8
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Section 26.1 pins the Datastar bundle under priv/static/vendor and forbids
  # loading it from a CDN, so it is served from this origin like any asset.
  plug Plug.Static,
    at: "/static",
    from: :dispatch,
    gzip: false,
    only: ~w(css js vendor favicon.ico robots.txt)

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId, assign_as: :correlation_id
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 1_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug DispatchWeb.Router
end
