defmodule FederationService do
  @moduledoc """
  Opt-in, read-only public discovery service. Start explicitly with a separate
  journal directory, an RSA private key and configured remote actor URLs.
  There is no public local-publication or business-command HTTP endpoint.
  """
  alias FederationService.{Store, Network, Signature, Delivery}
  alias FederationCore.Marketplace

  def config!(opts) do
    actor = Keyword.fetch!(opts, :actor)
    {:ok, _} = Network.uri(actor)
    peers = Keyword.get(opts, :peers, [])
    true = length(peers) <= 32 and length(Enum.uniq(peers)) == length(peers)

    Enum.each(peers, fn p ->
      {:ok, _} = Network.uri(p)
      true = URI.parse(p).host != URI.parse(actor).host
    end)

    %{
      actor: actor,
      private_key: Keyword.fetch!(opts, :private_key),
      peers: peers,
      store: Keyword.fetch!(opts, :store),
      network: Keyword.get(opts, :network, [])
    }
  end

  @doc "Host-only publication of an already-authorized, opted-in public projection and stable source event ID."
  def publish(config, event_id, metadata, kind \\ :create) do
    with true <- is_binary(event_id) and byte_size(event_id) in 1..256,
         true <- metadata["seller"] == config.actor,
         {:ok, _} <- Marketplace.validate_metadata(metadata, config.actor),
         id <-
           config.actor <>
             "/activities/" <> Base.encode16(:crypto.hash(:sha256, event_id), case: :lower),
         url <- metadata["id"] <> ".json",
         {:ok, activity} <- Marketplace.publish(kind, metadata, id, url) do
      Store.call(
        config.store,
        {:publish, event_id, activity, metadata, config.peers, System.system_time(:second)}
      )
    else
      _ -> {:error, :publication_refused}
    end
  end

  def withdraw(config, event_id, listing_id) do
    with true <- is_binary(event_id) and byte_size(event_id) in 1..256,
         id <-
           config.actor <>
             "/activities/" <> Base.encode16(:crypto.hash(:sha256, event_id), case: :lower),
         {:ok, activity} <- Marketplace.withdraw(config.actor, listing_id, id) do
      Store.call(
        config.store,
        {:publish, event_id, activity, nil, config.peers, System.system_time(:second)}
      )
    else
      _ -> {:error, :publication_refused}
    end
  end

  @doc "Locally reconcile current public listings/tombstones to configured peers in bounded batches."
  def reconcile(config, now \\ System.system_time(:second)) do
    Store.call(config.store, {:reconcile, config.actor, config.peers, now})
  end

  @doc "Host-only request to resend current publications after a configured peer loses its cache."
  def redeliver(config, peer, now \\ System.system_time(:second)) do
    Store.call(config.store, {:redeliver, config.actor, config.peers, peer, now})
  end

  def deliver(config, now \\ System.system_time(:second)) do
    {:ok, _} = reconcile(config, now)
    snapshot = Store.call(config.store, :snapshot)

    snapshot.outbox
    |> Enum.filter(fn {_, r} ->
      r.status == :pending and r.next_at <= now and
        Delivery.ready?(snapshot, config.actor, config.peers, r)
    end)
    |> Enum.sort_by(fn {key, row} ->
      {if(row.activity["type"] == "Delete", do: 0, else: 1), row.next_at, key}
    end)
    |> Enum.take(16)
    |> Enum.each(fn {key, row} ->
      success =
        with true <- row.destination in config.peers,
             true <- Delivery.ready?(snapshot, config.actor, config.peers, row),
             {:ok, remote} <- Signature.discover(row.destination, config.network),
             body <- Jason.encode!(row.activity),
             headers <- Signature.sign(remote.inbox, config.actor, config.private_key, body),
             true <-
               Delivery.ready?(
                 Store.call(config.store, :snapshot),
                 config.actor,
                 config.peers,
                 row
               ),
             {:ok, status, _, _} <-
               Network.request(:post, remote.inbox, headers, body, config.network) do
          status in [200, 202]
        else
          _ -> false
        end

      Store.call(config.store, {:delivery, key, Map.get(row, :generation, 0), success, now})
    end)
  end

  def refresh(config, now \\ System.system_time(:second)) do
    s = Store.call(config.store, :snapshot)

    s.remote
    |> Enum.filter(fn {_, r} ->
      not r.withdrawn and r.actor in config.peers and
        not Store.blocked?(s, r.actor, r.listing_id) and now - r.checked_at >= 900
    end)
    |> Enum.take(4)
    |> Enum.each(fn {id, r} ->
      metadata =
        case Network.json(r.metadata_url, config.network) do
          {:ok, m} -> m
          _ -> nil
        end

      Store.call(config.store, {:refresh, id, metadata, now})
    end)
  end

  def search(config, query \\ "", now \\ System.system_time(:second)) do
    s = Store.call(config.store, :snapshot)
    needle = query |> String.slice(0, 160) |> String.downcase()

    (Map.values(s.local) ++ Map.values(s.remote))
    |> Enum.reject(&(&1.withdrawn or Store.blocked?(s, &1.actor, &1.listing_id)))
    |> Enum.filter(fn r ->
      String.contains?(
        String.downcase(r.metadata["name"] <> " " <> r.metadata["summary"]),
        needle
      )
    end)
    |> Enum.sort_by(& &1.listing_id)
    |> Enum.take(100)
    |> Enum.map(fn r ->
      Map.merge(r, %{
        local: r.actor == config.actor,
        stale: now - r.verified_at > 3600,
        authority: "advertisement_only"
      })
    end)
  end
end
