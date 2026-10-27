defmodule FederationService.Inbox do
  @moduledoc "Authenticated public inbox. Its only write target is the discovery journal."
  alias FederationService.{JSON, Network, Signature, Store}
  alias FederationCore.{Marketplace, Subscriptions}

  def receive_request(config, path, headers, body, now \\ DateTime.utc_now()) do
    with true <- path == URI.parse(config.actor).path <> "/inbox",
         :ok <- Store.call(config.store, {:rate, :inbox, 120, DateTime.to_unix(now)}),
         {:ok, activity} <- JSON.decode(body),
         actor when is_binary(actor) <- activity["actor"],
         true <- actor != config.actor and actor in config.peers,
         false <- Store.blocked?(Store.call(config.store, :snapshot), actor, ""),
         :ok <- Store.call(config.store, {:rate, actor, 30, DateTime.to_unix(now)}),
         {:ok, identity} <- Signature.discover(actor, config.network),
         :ok <-
           Signature.verify(path, URI.parse(config.actor).host, headers, body, identity, now) do
      ingest_verified(config, activity, actor, body, DateTime.to_unix(now))
    else
      _ -> {:error, :inbox_refused}
    end
  rescue
    _ -> {:error, :inbox_refused}
  end

  defp ingest_verified(config, activity, actor, body, now) do
    case activity["type"] do
      kind when kind in ["Follow", "Accept", "Reject", "Undo"] ->
        with {:ok, candidate} <-
               Subscriptions.decode_verified(activity, %{
                 verified_actor: actor,
                 local_actor: config.actor
               }),
             false <- candidate.authoritative,
             false <- Store.blocked?(Store.call(config.store, :snapshot), actor, "") do
          Store.call(
            config.store,
            {:subscription, {:receive, activity, actor, config.actor, now}}
          )
        else
          _ -> {:error, :subscription_inbox_refused}
        end

      _ ->
        with {:ok, candidate} <-
               Marketplace.decode_verified(activity, %{verified_actor: actor}),
             false <-
               Store.blocked?(
                 Store.call(config.store, :snapshot),
                 actor,
                 candidate.listing_id
               ) do
          Store.call(
            config.store,
            {:enqueue, activity, candidate, :crypto.hash(:sha256, body), now}
          )
        else
          _ -> {:error, :listing_inbox_refused}
        end
    end
  end

  def drain(config, now \\ System.system_time(:second)) do
    snapshot = Store.call(config.store, :snapshot)

    snapshot.inbox
    |> Enum.filter(fn {_, v} -> v.status == :pending and v.next_at <= now end)
    |> Enum.take(16)
    |> Enum.each(fn {id, item} ->
      c = item.candidate

      cond do
        c.actor not in config.peers or Store.blocked?(snapshot, c.actor, c.listing_id) ->
          # Recheck current moderation immediately before committing.
          Store.call(config.store, {:reject, id, :blocked})

        c.kind == :delete or match?(%{withdrawn: true}, snapshot.remote[c.listing_id]) ->
          Store.call(config.store, {:project, id, nil, now})

        true ->
          with {:ok, metadata} <- Network.json(c.metadata_url, config.network) do
            Store.call(config.store, {:project, id, metadata, now})
          else
            _ -> Store.call(config.store, {:defer, id, now})
          end
      end
    end)
  end
end
