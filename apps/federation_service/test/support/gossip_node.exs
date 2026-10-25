# Harness-only local commands. No HTTP listener, remote command route or ledger dependency.
[directory, actor, executable, settings_file] = System.argv()
Application.ensure_all_started(:federation_service)
settings = Jason.decode!(File.read!(settings_file))
key_file = directory <> "/endpoint.key"
{:ok, _} = FederationService.Store.start_link(name: FederationService.Store, directory: directory)

service =
  FederationService.config!(actor: actor, private_key: nil, store: FederationService.Store)

config =
  FederationService.Gossip.config!(service,
    scope: settings["scope"],
    seed: File.read!(key_file),
    publisher_keys: settings["publisher_keys"]
  )

service = config.service

{:ok, worker} =
  FederationService.GossipWorker.start_link(
    config: config,
    executable: executable,
    key_file: key_file,
    peers: settings["peers"],
    allowed_endpoints: settings["allowed_endpoints"],
    bind: settings["bind"]
  )

address =
  Enum.reduce_while(1..100, nil, fn _, _ ->
    case FederationService.GossipWorker.address(worker) do
      nil ->
        Process.sleep(50)
        {:cont, nil}

      address ->
        {:halt, address}
    end
  end)

true = address != nil
ledger = directory <> "/signed-ledger.sentinel"
unless File.exists?(ledger), do: File.write!(ledger, "locally-owned-signed-history", [:exclusive])
IO.puts("READY " <> Jason.encode!(address))

Stream.repeatedly(fn -> IO.gets("") end)
|> Enum.reduce_while(nil, fn
  :eof, _ ->
    {:halt, nil}

  line, _ ->
    request = Jason.decode!(line)

    result =
      case request["op"] do
        "publish" ->
          FederationService.publish(
            service,
            request["event"],
            request["metadata"],
            if(request["revision"] == 0, do: :create, else: :update)
          )

        "withdraw" ->
          FederationService.withdraw(service, request["event"], request["id"])

        "renew" ->
          data = FederationService.Store.call(service.store, :snapshot)

          case data.local[request["id"]] do
            nil -> {:error, :unknown_listing}
            row -> FederationService.GossipLease.renew(config, row.activity_id)
          end

        "catchup" ->
          data = FederationService.Store.call(service.store, :snapshot)
          ids = Enum.map(data.local, fn {_, row} -> row.activity_id end)
          FederationService.GossipSync.start_round(config, request["receiver"], ids)

        "catchup_status" ->
          case FederationService.GossipSync.status(config, request["round"]) do
            {:ok, value} -> value
            error -> error
          end

        "snapshot" ->
          data = FederationService.Store.call(service.store, :snapshot)

          %{
            listings: FederationService.search(service),
            withdrawn: Enum.count(data.remote, fn {_, row} -> row.withdrawn end),
            inbox: map_size(data.gossip_inbox),
            completed_rounds:
              Enum.count(data.sync_outgoing, fn {_, row} -> row.status == :complete end),
            ledger: File.read!(ledger),
            events: map_size(data.events)
          }

        "stop" ->
          System.halt(0)
      end

    json =
      case result do
        {:ok, status} -> %{ok: true, status: status}
        {:error, reason} -> %{ok: false, reason: reason}
        value -> value
      end

    IO.puts("RESULT " <> Jason.encode!(json))
    {:cont, nil}
end)
