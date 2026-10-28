defmodule FederationService.GossipLease do
  @moduledoc "Explicit publisher freshness assertions with durable sequence and absolute expiry."
  alias FederationService.{Gossip, GossipSync, JSON, Store}
  @schema "bizkit.marketplace.halaqa-freshness.v1"
  @scope ~w(halaqa_id charter_hash epoch)
  @fields ~w(schema halaqa_id charter_hash epoch actor publisher listing_id activity_id hash sequence issued expires announcement signature)
  @max 9_007_199_254_740_991

  def renew(config, activity_id, ttl \\ 3600, now \\ System.system_time(:second)) do
    Store.call(config.service.store, {:lease_issue, context(config), activity_id, ttl, now})
  end

  defp context(config),
    do: %{
      actor: config.service.actor,
      scope: config.scope,
      publisher_keys: config.publisher_keys,
      topic: Gossip.topic(config)
    }

  defp key(ctx, publisher, listing_id) do
    hash = :crypto.hash(:sha256, GossipSync.canonical([ctx.topic, publisher, listing_id]))
    "lease:" <> Base.encode16(hash, case: :lower)
  end

  @doc false
  def issue(data, ctx, activity_id, ttl, now) do
    with true <- is_integer(ttl) and ttl in 1..3600,
         true <- is_integer(now) and now in 0..(@max - 3600),
         %{"actor" => actor, "object" => %{"id" => listing_id}} = activity <-
           data.publications[activity_id],
         true <- actor == ctx.actor,
         %{activity_id: ^activity_id, withdrawn: false} = row <- data.local[listing_id],
         false <- Store.blocked?(data, actor, listing_id),
         hash when is_binary(hash) <- GossipSync.content_hash(activity, row.metadata),
         publisher <- ctx.publisher_keys[actor],
         storage_key <- key(ctx, publisher, listing_id),
         old <- data.lease_local[storage_key],
         true <- old == nil or old.message["issued"] <= now,
         sequence <- if(old == nil, do: 1, else: old.message["sequence"] + 1),
         true <- sequence <= @max,
         true <- old != nil or map_size(data.lease_local) < 10_000 do
      message =
        Map.merge(ctx.scope, %{
          "schema" => @schema,
          "actor" => actor,
          "publisher" => publisher,
          "listing_id" => listing_id,
          "activity_id" => activity_id,
          "hash" => hash,
          "sequence" => sequence,
          "issued" => now,
          "expires" => now + ttl
        })

      {:ok, storage_key, %{message: message, last_sent: nil}}
    else
      _ -> {:error, :lease_refused}
    end
  end

  def receive_event(config, wire, now \\ System.system_time(:second)) do
    case JSON.decode(wire) do
      {:ok, %{"schema" => @schema} = m} ->
        with :ok <- Store.call(config.service.store, {:rate, :gossip, 120, now}),
             true <- Enum.sort(Map.keys(m)) == Enum.sort(@fields),
             true <- Map.take(m, @scope) === config.scope and m["actor"] != config.service.actor,
             true <- config.publisher_keys[m["actor"]] == m["publisher"],
             true <-
               hex?(m["publisher"], 64) and hex?(m["hash"], 64) and hex?(m["announcement"], 32),
             true <-
               Enum.all?(~w(listing_id activity_id), fn k ->
                 is_binary(m[k]) and byte_size(m[k]) in 1..2048
               end),
             true <- is_integer(m["sequence"]) and m["sequence"] in 1..@max,
             true <- times?(m, now),
             {:ok, public} <- Base.decode16(m["publisher"], case: :lower),
             {:ok, signature} <- Base.decode64(m["signature"]),
             true <- byte_size(signature) == 64,
             true <-
               :crypto.verify(
                 :eddsa,
                 :none,
                 GossipSync.canonical(Map.delete(m, "signature")),
                 signature,
                 [public, :ed25519]
               ),
             :ok <- Store.call(config.service.store, {:rate, {:gossip, m["actor"]}, 30, now}) do
          Store.call(config.service.store, {:lease_accept, context(config), m, now})
        else
          _ -> {:error, :lease_refused}
        end

      _ ->
        :not_lease
    end
  rescue
    _ -> {:error, :lease_refused}
  end

  defp times?(m, now) do
    is_integer(m["issued"]) and m["issued"] in 0..(@max - 3600) and
      is_integer(m["expires"]) and (m["expires"] - m["issued"]) in 1..3600 and
      m["issued"] <= now + 30 and m["expires"] > now
  end

  @doc false
  def accept(data, ctx, signed, now) do
    m = Map.drop(signed, ~w(signature announcement))
    storage_key = key(ctx, m["publisher"], m["listing_id"])
    old = data.lease_remote[storage_key]

    cond do
      not times?(m, now) or not bound?(data, ctx, m, :remote) ->
        {:error, :lease_refused}

      old != nil and m["sequence"] < old.message["sequence"] ->
        {:error, :stale_lease}

      old != nil and m["sequence"] == old.message["sequence"] and m != old.message ->
        {:error, :lease_conflict}

      old != nil and m == old.message ->
        {:ok, :duplicate}

      old != nil and m["issued"] < old.message["issued"] ->
        {:error, :stale_lease}

      old == nil and map_size(data.lease_remote) >= 10_000 ->
        {:error, :capacity}

      true ->
        {:ok, storage_key, %{message: m, signed_message: signed}}
    end
  end

  defp bound?(data, ctx, m, side) do
    row = if side == :local, do: data.local[m["listing_id"]], else: data.remote[m["listing_id"]]

    activity =
      if side == :local do
        data.publications[m["activity_id"]]
      else
        case data.gossip_inbox[m["activity_id"]] do
          %{status: :applied} = item ->
            if item.metadata == (row && row.metadata) and
                 Map.take(item.envelope, @scope) === ctx.scope and
                 item.envelope["publisher"] == m["publisher"],
               do: item.activity

          _ ->
            nil
        end
      end

    m["actor"] != nil and ctx.publisher_keys[m["actor"]] == m["publisher"] and
      Map.take(m, @scope) === ctx.scope and row != nil and not row.withdrawn and
      row.actor == m["actor"] and row.activity_id == m["activity_id"] and
      not Store.blocked?(data, row.actor, row.listing_id) and
      (side == :local or
         (Map.get(row, :transport) == "iroh-gossip" and
            row.halaqa_scope === ctx.scope and row.publisher_key == m["publisher"])) and
      is_map(activity) and is_binary(m["hash"]) and
      GossipSync.content_hash(activity, row.metadata) == m["hash"]
  end

  def frames(config, now, exclude) do
    data = Store.call(config.service.store, :snapshot)
    ctx = context(config)

    data.lease_local
    |> Enum.filter(fn {base, row} ->
      not MapSet.member?(exclude, token(base, row)) and due?(data, ctx, row, now)
    end)
    |> Enum.sort_by(fn {base, row} -> {row.last_sent || 0, base} end)
    |> Enum.take(4)
    |> Enum.map(fn {base, row} -> {token(base, row), sign(config, row.message)} end)
  end

  def current?(config, id, now) do
    data = Store.call(config.service.store, :snapshot)

    case entry(data, id) do
      {_, row} -> due?(data, context(config), row, now)
      nil -> false
    end
  end

  defp due?(data, ctx, row, now),
    do:
      row.message["actor"] == ctx.actor and
        row.message["issued"] <= now and now < row.message["expires"] and
        (row.last_sent == nil or now - row.last_sent >= 30) and
        bound?(data, ctx, row.message, :local)

  @doc false
  def entry(data, id) do
    case String.split(id, ":") do
      ["lease", hash, sequence] ->
        base = "lease:" <> hash

        case data.lease_local[base] do
          %{message: %{"sequence" => n}} = row ->
            if Integer.to_string(n) == sequence, do: {base, row}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def sent(config, id, now), do: Store.call(config.service.store, {:lease_sent, id, now})

  def sent_at(data, id) do
    case entry(data, id) do
      {_, row} -> row.last_sent || 0
      nil -> 0
    end
  end

  defp token(base, row), do: base <> ":" <> Integer.to_string(row.message["sequence"])

  def freshness(service, row, data, now) do
    fallback =
      if Map.get(row, :transport) == "iroh-gossip" and
           get_in(service, [:gossip_policy, :require_freshness_lease]) == true do
        %{stale: true, freshness_source: "none", freshness_expires_at: nil}
      else
        %{
          stale: now - row.verified_at > 3600,
          freshness_source: "projection",
          freshness_expires_at: row.verified_at + 3600
        }
      end

    case Map.get(service, :gossip_policy) do
      %{scope: scope, publisher_keys: keys} ->
        ctx = %{
          actor: service.actor,
          scope: scope,
          publisher_keys: keys,
          topic: Gossip.topic(%{scope: scope})
        }

        storage_key = key(ctx, keys[row.actor], row.listing_id)
        side = if row.actor == service.actor, do: :local, else: :remote
        table = if side == :local, do: data.lease_local, else: data.lease_remote

        case table[storage_key] do
          %{message: m} ->
            if bound?(data, ctx, m, side),
              do: %{
                stale: now < m["issued"] or now >= m["expires"],
                freshness_source: "publisher_lease",
                freshness_expires_at: m["expires"]
              },
              else: fallback

          _ ->
            fallback
        end

      _ ->
        fallback
    end
  end

  defp hex?(v, n), do: is_binary(v) and byte_size(v) == n and Regex.match?(~r/\A[0-9a-f]+\z/, v)

  defp sign(config, m) do
    m = Map.put(m, "announcement", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))

    signature =
      :crypto.sign(:eddsa, :none, GossipSync.canonical(m), [config.seed, :ed25519])
      |> Base.encode64()

    Jason.encode!(Map.put(m, "signature", signature))
  end
end
