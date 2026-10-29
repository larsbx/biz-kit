defmodule FederationService.Node do
  @moduledoc "Explicit standalone host supervisor; not enabled in biz-kit releases by default."
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def init(opts) do
    store = Keyword.get(opts, :store_name, FederationService.Store)

    config =
      FederationService.config!(
        actor: Keyword.fetch!(opts, :actor),
        handle: Keyword.get(opts, :handle),
        approval_verifier: Keyword.get(opts, :approval_verifier),
        subscription_authority: Keyword.get(opts, :subscription_authority),
        peers: Keyword.get(opts, :peers, []),
        store: store,
        private_key: FederationService.Signature.private!(Keyword.fetch!(opts, :signing_keyfile)),
        network: Keyword.get(opts, :network, [])
      )

    children = [
      {FederationService.Store, [name: store, directory: Keyword.fetch!(opts, :directory)]},
      {Bandit,
       [
         plug: {FederationService.Router, config},
         scheme: :https,
         ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
         port: Keyword.get(opts, :port, 8443),
         certfile: Keyword.fetch!(opts, :certfile),
         keyfile: Keyword.fetch!(opts, :keyfile),
         http_2_options: [enabled: false],
         http_1_options: [
           max_header_count: 40,
           max_header_length: 8192,
           max_request_line_length: 4096
         ],
         thousand_island_options: [num_acceptors: 4, num_connections: 32, read_timeout: 5000],
         startup_log: false
       ]}
    ]

    children =
      if Keyword.get(opts, :worker, true),
        do: children ++ [{FederationService.Worker, config}],
        else: children

    Supervisor.init(children, strategy: :one_for_all)
  end
end
