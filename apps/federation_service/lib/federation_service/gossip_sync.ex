defmodule FederationService.GossipSync do
  @moduledoc "Signed, bounded catch-up rounds; completion acknowledges durable historical projections only."
  alias FederationService.{Gossip, JSON, Store}
  @schema "bizkit.marketplace.halaqa-catchup.v1"
  @scope ~w(halaqa_id charter_hash epoch)
  @common ~w(schema kind halaqa_id charter_hash epoch from to publisher round batch expires announcement signature)

  # Canonical JSON for this profile: sorted UTF-8 object keys, ordered arrays,
  # Jason's JSON string escaping and integer spelling. No floating point values.
  def canonical(value) when is_map(value) do
    "{" <>
      (value
       |> Enum.sort()
       |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <>
      "}"
  end

  def canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  def canonical(value)
      when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
      do: Jason.encode!(value)

  def content_hash(activity, metadata),
    do: digest(%{"activity" => activity, "metadata" => metadata})

  defp digest(value), do: :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)

  defp hex?(value, n),
    do: is_binary(value) and byte_size(value) == n and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp id(message), do: "sync:" <> digest(Map.take(message, ~w(kind from to round)))

  def start_round(config, receiver, activity_ids, now \\ System.system_time(:second)) do
    data = Store.call(config.service.store, :snapshot)

    with true <-
           receiver != config.service.actor and Map.has_key?(config.publisher_keys, receiver),
         false <- Store.blocked?(data, receiver, ""),
         true <- is_list(activity_ids) and length(activity_ids) in 1..16,
         true <- length(Enum.uniq(activity_ids)) == length(activity_ids),
         true <- Enum.all?(activity_ids, &Gossip.current?(config, &1)),
         entries <-
           Enum.map(Enum.sort(activity_ids), fn activity_id ->
             activity = data.publications[activity_id]
             row = data.local[activity["object"]["id"]]
             %{"id" => activity_id, "hash" => content_hash(activity, row.metadata)}
           end) do
      message =
        Map.merge(config.scope, %{
          "schema" => @schema,
          "kind" => "offer",
          "from" => config.service.actor,
          "to" => receiver,
          "publisher" => config.publisher,
          "round" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "entries" => entries,
          "expires" => now + 3600
        })

      message = Map.put(message, "batch", batch(message))

      row = %{
        message: message,
        peer_key: config.publisher_keys[receiver],
        status: :pending,
        last_sent: nil
      }

      case Store.call(config.service.store, {:sync_put, :sync_outgoing, id(message), row}) do
        :ok -> {:ok, message["round"]}
        error -> error
      end
    else
      _ -> {:error, :catchup_refused}
    end
  rescue
    _ -> {:error, :catchup_refused}
  end

  def status(config, round, now \\ System.system_time(:second)) do
    data = Store.call(config.service.store, :snapshot)

    case Enum.find(data.sync_outgoing, fn {_, row} -> row.message["round"] == round end) do
      {_, row} ->
        cond do
          not current_policy?(config, row, :sync_outgoing, data) ->
            {:error, :catchup_refused}

          row.status == :complete ->
            {:ok,
             %{
               state: :complete,
               receipt: row.receipt,
               current: sources_current?(config, row.message, data)
             }}

          row.message["expires"] <= now ->
            {:ok, %{state: :expired}}

          not sources_current?(config, row.message, data) ->
            {:ok, %{state: :superseded}}

          true ->
            {:ok, %{state: :pending}}
        end

      nil ->
        {:error, :unknown_round}
    end
  end

  def receive_event(config, wire, now \\ System.system_time(:second)) do
    case JSON.decode(wire) do
      {:ok, %{"schema" => @schema} = message} ->
        with :ok <- Store.call(config.service.store, {:rate, :gossip, 120, now}),
             {:ok, message} <- verify(config, message, now),
             :ok <- Store.call(config.service.store, {:rate, {:gossip, message["from"]}, 30, now}) do
          accept(config, message, now)
        else
          _ -> {:error, :catchup_refused}
        end

      _ ->
        :not_sync
    end
  rescue
    _ -> {:error, :catchup_refused}
  end

  defp verify(config, m, now) do
    extra =
      case m["kind"] do
        "offer" -> ["entries"]
        "receipt" -> ["journal"]
        _ -> []
      end

    data = Store.call(config.service.store, :snapshot)

    with true <- extra != [] and Enum.sort(Map.keys(m)) == Enum.sort(@common ++ extra),
         true <- Map.take(m, @scope) === config.scope and m["to"] == config.service.actor,
         true <-
           m["from"] != config.service.actor and
             config.publisher_keys[m["from"]] == m["publisher"],
         false <- Store.blocked?(data, m["from"], ""),
         true <-
           hex?(m["publisher"], 64) and hex?(m["round"], 32) and hex?(m["batch"], 64) and
             hex?(m["announcement"], 32),
         true <- is_integer(m["expires"]) and m["expires"] > now and m["expires"] <= now + 3600,
         {:ok, key} <- Base.decode16(m["publisher"], case: :lower),
         {:ok, sig} <- Base.decode64(m["signature"]),
         true <- byte_size(sig) == 64,
         true <-
           :crypto.verify(:eddsa, :none, canonical(Map.delete(m, "signature")), sig, [
             key,
             :ed25519
           ]),
         true <- valid_body?(m) do
      {:ok, m}
    else
      _ -> {:error, :catchup_refused}
    end
  end

  defp valid_body?(%{"kind" => "offer", "entries" => entries} = m) when is_list(entries) do
    length(entries) in 1..16 and
      Enum.all?(entries, fn e ->
        is_map(e) and Enum.sort(Map.keys(e)) == ~w(hash id) and
          is_binary(e["id"]) and byte_size(e["id"]) in 1..2048 and hex?(e["hash"], 64)
      end) and
      Enum.map(entries, & &1["id"]) ==
        entries |> Enum.map(& &1["id"]) |> Enum.uniq() |> Enum.sort() and
      batch(m) == m["batch"]
  end

  defp valid_body?(%{"kind" => "receipt", "journal" => journal}), do: hex?(journal, 32)
  defp valid_body?(_), do: false

  defp batch(m),
    do: m |> Map.take(@scope ++ ~w(schema from to publisher round entries expires)) |> digest()

  defp accept(config, %{"kind" => "offer"} = m, _) do
    row = %{
      signed_offer: m,
      message: Map.drop(m, ~w(signature announcement)),
      peer_key: m["publisher"],
      status: :pending,
      last_sent: nil
    }

    Store.call(config.service.store, {:sync_put, :sync_incoming, id(m), row})
  end

  defp accept(config, %{"kind" => "receipt"} = m, now) do
    Store.call(
      config.service.store,
      {:sync_receipt, m, config.scope, config.publisher_keys[m["from"]], config.publisher, now}
    )
  end

  def drain(config, now \\ System.system_time(:second)) do
    data = Store.call(config.service.store, :snapshot)

    data.sync_incoming
    |> Enum.filter(fn {_, row} ->
      row.status == :pending and row.message["expires"] > now and
        current_policy?(config, row, :sync_incoming, data) and applied?(config, row.message, data)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(16)
    |> Enum.each(fn {key, _row} ->
      Store.call(config.service.store, {:sync_complete, key})
    end)
  end

  defp applied?(config, m, data) do
    Enum.all?(m["entries"], fn entry ->
      case data.gossip_inbox[entry["id"]] do
        %{status: :applied} = item ->
          item.candidate.actor == m["from"] and item.envelope["publisher"] == m["publisher"] and
            Map.take(item.envelope, @scope) === config.scope and
            not Store.blocked?(data, item.candidate.actor, item.candidate.listing_id) and
            content_hash(item.activity, item.metadata) == entry["hash"]

        _ ->
          false
      end
    end)
  end

  def frames(config, now, exclude) do
    data = Store.call(config.service.store, :snapshot)

    [:sync_incoming, :sync_outgoing]
    |> Enum.flat_map(fn table ->
      for {key, row} <- Map.fetch!(data, table),
          not MapSet.member?(exclude, key),
          due?(config, table, row, data, now),
          do: {table, key, row}
    end)
    |> Enum.sort_by(fn {_, key, row} -> {row.last_sent || 0, key} end)
    |> Enum.take(4)
    |> Enum.map(fn {table, key, row} ->
      message =
        if table == :sync_outgoing,
          do: row.message,
          else: receipt(config, row.message, data.sync_meta.journal)

      {key, sign(config, message)}
    end)
  end

  def current?(config, key, now) do
    data = Store.call(config.service.store, :snapshot)

    Enum.any?([:sync_incoming, :sync_outgoing], fn table ->
      case Map.fetch!(data, table)[key] do
        nil -> false
        row -> due?(config, table, row, data, now)
      end
    end)
  end

  def sent(config, key, now), do: Store.call(config.service.store, {:sync_sent, key, now})

  defp due?(config, table, row, data, now) do
    row.message["expires"] > now and (row.last_sent == nil or now - row.last_sent >= 30) and
      current_policy?(config, row, table, data) and
      if(table == :sync_outgoing,
        do: row.status == :pending and sources_current?(config, row.message, data),
        else: row.status == :complete and applied?(config, row.message, data)
      )
  end

  defp current_policy?(config, row, table, data) do
    m = row.message

    {local, peer} =
      if table == :sync_outgoing, do: {m["from"], m["to"]}, else: {m["to"], m["from"]}

    Map.take(m, @scope) === config.scope and local == config.service.actor and
      config.publisher_keys[peer] == row.peer_key and not Store.blocked?(data, peer, "") and
      (table != :sync_outgoing or m["publisher"] == config.publisher)
  end

  defp sources_current?(config, m, data) do
    Enum.all?(m["entries"], fn entry ->
      with %{"actor" => actor, "object" => %{"id" => listing_id}} = activity <-
             data.publications[entry["id"]],
           true <- actor == config.service.actor,
           %{activity_id: activity_id, actor: ^actor} = row <- data.local[listing_id] do
        activity_id == entry["id"] and
          (row.withdrawn or not Store.blocked?(data, actor, listing_id)) and
          content_hash(activity, row.metadata) == entry["hash"]
      else
        _ -> false
      end
    end)
  end

  defp receipt(config, m, journal) do
    m
    |> Map.drop(~w(entries))
    |> Map.merge(%{
      "kind" => "receipt",
      "from" => m["to"],
      "to" => m["from"],
      "publisher" => config.publisher,
      "journal" => journal
    })
  end

  defp sign(config, m) do
    m = Map.put(m, "announcement", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
    sig = :crypto.sign(:eddsa, :none, canonical(m), [config.seed, :ed25519]) |> Base.encode64()
    wire = m |> Map.put("signature", sig) |> canonical()
    true = byte_size(wire) <= 65_536
    wire
  end
end
