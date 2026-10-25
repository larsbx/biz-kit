# Harness-only control channel on stdin. Never expose these operations over HTTP.
[dir, host, port, remote, remote_port, cert_dir | extra] = System.argv()

peers =
  case extra do
    [] -> ["https://#{remote}/actors/shop"]
    [value] -> Jason.decode!(value)
  end

Application.ensure_all_started(:federation_service)
[ca] = :public_key.pem_decode(File.read!(cert_dir <> "/ca.pem"))
key_path = dir <> "/signing.key"
File.mkdir_p!(dir)

unless File.exists?(key_path) do
  key = :public_key.generate_key({:rsa, 2048, 65537})

  File.write!(
    key_path,
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)]),
    [:exclusive]
  )

  File.chmod!(key_path, 0o600)
end

store = FederationService.Store

config =
  FederationService.config!(
    actor: "https://#{host}/actors/shop",
    private_key: FederationService.Signature.private!(key_path),
    peers: peers,
    store: store,
    network: [
      test_routes: %{
        host => {{127, 0, 0, 1}, String.to_integer(port)},
        remote => {{127, 0, 0, 1}, String.to_integer(remote_port)}
      },
      test_cacerts: [elem(ca, 1)]
    ]
  )

{:ok, _} =
  FederationService.Node.start_link(
    actor: config.actor,
    peers: config.peers,
    signing_keyfile: key_path,
    directory: dir,
    network: config.network,
    port: String.to_integer(port),
    certfile: cert_dir <> "/#{host}.pem",
    keyfile: cert_dir <> "/#{host}.key",
    worker: false
  )

# A sentinel represents an independently owned signed ledger. FederationService
# has neither a dependency nor an endpoint capable of dispatching to it.
ledger = dir <> "/signed-ledger.sentinel"
unless File.exists?(ledger), do: File.write!(ledger, "locally-owned-signed-history", [:exclusive])
IO.puts("READY")

Stream.repeatedly(fn -> IO.gets("") end)
|> Enum.reduce_while(nil, fn
  :eof, _ ->
    {:halt, nil}

  line, _ ->
    req = Jason.decode!(line)

    result =
      case req["op"] do
        "publish" ->
          FederationService.publish(
            config,
            req["event"],
            req["metadata"],
            if(req["revision"] == 0, do: :create, else: :update)
          )

        "withdraw" ->
          FederationService.withdraw(config, req["event"], req["id"])

        "drain" ->
          FederationService.Inbox.drain(config)
          :ok

        "reconcile" ->
          {:ok, stats} = FederationService.reconcile(config)
          %{ok: true, stats: stats}

        "redeliver" ->
          FederationService.redeliver(config, req["peer"])

        "deliver" ->
          FederationService.deliver(config)
          :ok

        "snapshot" ->
          s = FederationService.Store.call(store, :snapshot)

          %{
            inbox_count: map_size(s.inbox),
            pending: Enum.count(s.outbox, fn {_, r} -> r.status == :pending end),
            held: Enum.count(s.outbox, fn {_, r} -> r.status == :held end),
            superseded: Enum.count(s.outbox, fn {_, r} -> r.status == :superseded end),
            remote_withdrawn: Enum.count(s.remote, fn {_, r} -> r.withdrawn end),
            listings: FederationService.search(config),
            ledger: File.read!(ledger)
          }

        "block" ->
          FederationService.Store.call(store, {:block, req["key"], req["blocked"]})

        "stop" ->
          System.halt(0)
      end

    serializable =
      case result do
        :ok -> %{"ok" => true}
        {:ok, status} -> %{"ok" => true, "status" => to_string(status)}
        {:error, reason} -> %{"ok" => false, "reason" => to_string(reason)}
        %{} -> result
      end

    IO.puts("RESULT " <> Jason.encode!(serializable))
    {:cont, nil}
end)
