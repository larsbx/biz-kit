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
      {Phoenix.PubSub, name: Dispatch.PubSub}
    ] ++ outbox_children() ++ [
      {Finch,
       name: Dispatch.Finch, pools: %{default: [conn_opts: [transport_opts: transport_opts()]]}},
      # Serialises OIDC key refreshes so a burst of unknown key IDs cannot turn
      # into a burst of outbound fetches. Started after Finch, which it uses.
      Dispatch.Identity.Tokens.KeyStore,
      DispatchWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Dispatch.Supervisor)
  end

  defp outbox_children do
    if Application.get_env(:dispatch, :start_outbox_publisher, true) do
      [Dispatch.Outbox.Publisher]
    else
      []
    end
  end

  # Section 23.1 makes the OIDC issuer's published keys the root of trust for
  # every authenticated request, so the connection that fetches them verifies
  # its peer. Stated here rather than inherited from a library default: a
  # transitive dependency changing that default must not silently change this.
  # The connect allowance is read from configuration rather than written here,
  # because `Dispatch.Identity.Tokens.Oidc` sizes its refresh deadline against
  # the same number; two copies would drift and the deadline would silently
  # become too short.
  defp transport_opts do
    [timeout: Dispatch.Identity.Tokens.Oidc.connect_timeout_ms()] ++ tls_opts()
  end

  defp tls_opts do
    [
      verify: :verify_peer,
      cacertfile: CAStore.file_path(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  @impl Application
  def config_change(changed, _new, removed) do
    DispatchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
