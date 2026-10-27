defmodule FederationService do
  @moduledoc """
  Opt-in, read-only public discovery service. Start explicitly with a separate
  journal directory, an RSA private key and configured remote actor URLs.
  There is no public local-publication or business-command HTTP endpoint.
  """
  alias FederationService.{Store, Network, Signature, Delivery, WebFinger, SubscriptionDelivery}
  alias FederationCore.Marketplace

  def config!(opts) do
    actor = Keyword.fetch!(opts, :actor)
    {:ok, _} = Network.uri(actor)
    handle = WebFinger.handle!(Keyword.get(opts, :handle))
    peers = Keyword.get(opts, :peers, [])
    true = length(peers) <= 32 and length(Enum.uniq(peers)) == length(peers)

    Enum.each(peers, fn p ->
      {:ok, _} = Network.uri(p)
      true = URI.parse(p).host != URI.parse(actor).host
    end)

    %{
      actor: actor,
      handle: handle,
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

  @doc """
  Host-only initiation of a public subscription to an explicitly configured peer.
  The host must independently authorize this local instruction before calling.
  """
  def follow(config, peer, source_id, now \\ System.system_time(:second)) do
    with true <- peer in config.peers,
         true <- is_binary(source_id) and byte_size(source_id) in 1..256,
         id <- event_id(config.actor, source_id),
         {:ok, activity} <- FederationCore.Subscriptions.follow(config.actor, peer, id) do
      Store.call(
        config.store,
        {:subscription_host, config.actor, config.peers, {:begin, activity, now}}
      )
    else
      _ -> {:error, :subscription_follow_refused}
    end
  end

  @doc """
  Host-only approval/rejection of a pending inbound Follow. The receipt
  MUST originate from independently verified local authority, not a user form.
  """
  def respond_follow(config, follow_id, decision, source_id, receipt, now \\ System.system_time(:second))
      when decision in [:accept, :reject] do
    with true <- is_binary(source_id) and byte_size(source_id) in 1..256 do
      Store.call(
        config.store,
        {:subscription_host, config.actor, config.peers,
         {:decide, follow_id, decision, event_id(config.actor, source_id), receipt, now}}
      )
    else
      _ -> {:error, :subscription_decision_refused}
    end
  end

  def respond_follow(_, _, _, _, _, _), do: {:error, :subscription_decision_refused}

  @doc "Host-only withdrawal of a locally initiated Follow."
  def undo_follow(config, follow_id, source_id, receipt, now \\ System.system_time(:second)) do
    with true <- is_binary(source_id) and byte_size(source_id) in 1..256 do
      Store.call(
        config.store,
        {:subscription_host, config.actor, config.peers,
         {:cancel, follow_id, event_id(config.actor, source_id), receipt, now}}
      )
    else
      _ -> {:error, :subscription_cancel_refused}
    end
  end

  defp event_id(actor, source_id) do
    actor <> "/activities/" <>
      Base.encode16(:crypto.hash(:sha256, source_id), case: :lower)
  end

  @doc "Deliver bounded, signed control activities from the same durable discovery journal."
  def deliver_subscriptions(config, now \\ System.system_time(:second)),
    do: SubscriptionDelivery.deliver(config, now)

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
      not r.withdrawn and Map.get(r, :transport) != "iroh-gossip" and r.actor in config.peers and
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
    |> Enum.reject(
      &(&1.withdrawn or Store.blocked?(s, &1.actor, &1.listing_id) or
          not FederationService.Gossip.visible?(config, &1))
    )
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
        authority: "advertisement_only"
      })
      |> Map.merge(FederationService.GossipLease.freshness(config, r, s, now))
    end)
  end
end
