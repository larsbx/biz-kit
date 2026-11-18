defmodule TaskHost.Web.Endpoint do
  @moduledoc """
  The task host's endpoint: `/auth`, the web view, its signed commands and
  the change feed, each request rate-limited before its body is read.
  Every decision is the ledger's (`CoopSubstrate`) or identity's
  (`BizKit.Identity`); the host carries requests.
  """

  # Bandit rather than Cowboy. Phoenix defaults to Cowboy, which is not a
  # dependency here, so the adapter is set in the endpoint config
  # (see config/config.exs).
  use Phoenix.Endpoint, otp_app: :task_host

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:task_host, :endpoint])

  # Before any body is read.
  plug(TaskHost.Web.RateLimit)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(TaskHost.Web.Router)
end
