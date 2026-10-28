defmodule FederationService.Gossip do
  @moduledoc "Experimental Halaqa-scoped signed advertisements over opaque gossip transport."
  alias FederationCore.Marketplace
  alias FederationService.{JSON, Store}
  @schema "bizkit.marketplace.halaqa-gossip.v1"
  @max 9_007_199_254_740_991

  def config!(service, opts) do
    scope = Keyword.fetch!(opts, :scope)
    true = Enum.sort(Map.keys(scope)) == ~w(charter_hash epoch halaqa_id)

    true =
      is_binary(scope["halaqa_id"]) and
        Regex.match?(~r/\A[a-zA-Z0-9._-]{1,128}\z/, scope["halaqa_id"])

    true = hex?(scope["charter_hash"])
    true = is_integer(scope["epoch"]) and scope["epoch"] in 0..@max
    seed = Keyword.fetch!(opts, :seed)
    true = is_binary(seed) and byte_size(seed) == 32
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    keys = Keyword.fetch!(opts, :publisher_keys)
    true = is_map(keys) and map_size(keys) in 1..32

    Enum.each(keys, fn {actor, key} ->
      {:ok, _} = FederationService.Network.uri(actor)
      true = hex?(key)
    end)

    publisher = Base.encode16(public, case: :lower)
    true = keys[service.actor] == publisher
    require_lease = Keyword.get(opts, :require_freshness_lease, false)
    true = is_boolean(require_lease)

    service =
      Map.put(service, :gossip_policy, %{
        scope: scope,
        publisher_keys: keys,
        require_freshness_lease: require_lease
      })

    %{service: service, scope: scope, seed: seed, publisher: publisher, publisher_keys: keys}
  end

  def visible?(service, %{transport: "iroh-gossip"} = row) do
    case Map.get(service, :gossip_policy) do
      %{scope: scope, publisher_keys: keys} ->
        row.halaqa_scope === scope and keys[row.actor] == row.publisher_key

      _ ->
        false
    end
  end

  def visible?(_, _), do: true

  def topic(config),
    do: :crypto.hash(:sha256, scope_bytes(config.scope)) |> Base.encode16(case: :lower)

  def encode(config, activity, metadata) do
    with true <- activity["actor"] == config.service.actor,
         {:ok, candidate} <-
           Marketplace.decode_verified(activity, %{verified_actor: config.service.actor}),
         :ok <- metadata_bound(candidate, metadata) do
      payload =
        Jason.encode!(%{"activity" => activity, "metadata" => metadata}) |> Base.encode64()

      envelope =
        Map.merge(config.scope, %{
          "schema" => @schema,
          "publisher" => config.publisher,
          "announcement" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "payload" => payload
        })

      signature =
        :crypto.sign(:eddsa, :none, signing_bytes(envelope), [config.seed, :ed25519])
        |> Base.encode64()

      wire = envelope |> Map.put("signature", signature) |> Jason.encode!()
      if byte_size(wire) <= 65_536, do: {:ok, wire}, else: {:error, :message_limit}
    else
      _ -> {:error, :gossip_refused}
    end
  end

  def decode(config, wire) do
    with {:ok, envelope} <- JSON.decode(wire),
         true <-
           Enum.sort(Map.keys(envelope)) ==
             ~w(announcement charter_hash epoch halaqa_id payload publisher schema signature),
         true <-
           envelope["schema"] == @schema and
             Map.take(envelope, ~w(halaqa_id charter_hash epoch)) === config.scope,
         true <- hex?(envelope["publisher"]),
         true <-
           is_binary(envelope["announcement"]) and
             Regex.match?(~r/\A[0-9a-f]{32}\z/, envelope["announcement"]),
         {:ok, public} <- Base.decode16(envelope["publisher"], case: :lower),
         {:ok, signature} <- Base.decode64(envelope["signature"]),
         true <- byte_size(signature) == 64,
         true <-
           :crypto.verify(:eddsa, :none, signing_bytes(envelope), signature, [public, :ed25519]),
         {:ok, bytes} <- Base.decode64(envelope["payload"]),
         {:ok, %{"activity" => activity, "metadata" => metadata} = payload} <- JSON.decode(bytes),
         true <- map_size(payload) == 2,
         actor <- activity["actor"],
         true <-
           actor != config.service.actor and config.publisher_keys[actor] == envelope["publisher"],
         {:ok, candidate} <- Marketplace.decode_verified(activity, %{verified_actor: actor}),
         :ok <- metadata_bound(candidate, metadata) do
      {:ok, candidate, activity, metadata, envelope}
    else
      _ -> {:error, :gossip_refused}
    end
  rescue
    _ -> {:error, :gossip_refused}
  end

  def receive_event(config, wire, now \\ System.system_time(:second)) do
    with :ok <- Store.call(config.service.store, {:rate, :gossip, 120, now}),
         {:ok, c, activity, metadata, envelope} <- decode(config, wire),
         :ok <- Store.call(config.service.store, {:rate, {:gossip, c.actor}, 30, now}),
         false <-
           Store.blocked?(Store.call(config.service.store, :snapshot), c.actor, c.listing_id) do
      item = %{
        candidate: c,
        activity: activity,
        metadata: metadata,
        envelope: envelope,
        hash:
          :crypto.hash(:sha256, Jason.encode!(%{"activity" => activity, "metadata" => metadata})),
        received_at: now,
        status: :pending
      }

      Store.call(config.service.store, {:gossip_enqueue, item})
    else
      _ -> {:error, :gossip_refused}
    end
  end

  def drain(config, now \\ System.system_time(:second)) do
    data = Store.call(config.service.store, :snapshot)

    data.gossip_inbox
    |> Enum.filter(fn {_, item} ->
      item.status == :pending and
        Map.take(item.envelope, ~w(halaqa_id charter_hash epoch)) === config.scope
    end)
    |> Enum.sort_by(fn {id, item} -> {if(item.candidate.kind == :delete, do: 0, else: 1), id} end)
    |> Enum.take(16)
    |> Enum.each(fn {id, item} ->
      case decode(config, Jason.encode!(item.envelope)) do
        {:ok, _, _, _, _} ->
          Store.call(config.service.store, {:gossip_project, id, item.metadata, now})

        _ ->
          Store.call(config.service.store, {:gossip_reject, id, :publisher_revoked})
      end
    end)
  end

  def frames(config, now \\ System.system_time(:second), exclude \\ MapSet.new(), force \\ false) do
    data = Store.call(config.service.store, :snapshot)
    topic = topic(config)

    data.local
    |> Enum.sort_by(fn {id, row} ->
      {Map.get(data.gossip_sends, {topic, row.activity_id}, 0), if(row.withdrawn, do: 0, else: 1),
       id}
    end)
    |> Enum.filter(fn {id, row} ->
      row.actor == config.service.actor and not MapSet.member?(exclude, row.activity_id) and
        (row.withdrawn or not Store.blocked?(data, row.actor, id)) and
        (force or now - Map.get(data.gossip_sends, {topic, row.activity_id}, now - 30) >= 30)
    end)
    |> Enum.take(16)
    |> Enum.flat_map(fn {_, row} ->
      case encode(config, data.publications[row.activity_id], row.metadata) do
        {:ok, wire} -> [{row.activity_id, wire}]
        _ -> []
      end
    end)
  end

  def current?(config, activity_id) do
    data = Store.call(config.service.store, :snapshot)

    with %{"actor" => actor, "object" => %{"id" => id}} <- data.publications[activity_id],
         true <- actor == config.service.actor,
         %{activity_id: ^activity_id, actor: ^actor} = row <- data.local[id] do
      row.withdrawn or not Store.blocked?(data, actor, id)
    else
      _ -> false
    end
  end

  defp metadata_bound(%{kind: :delete}, nil), do: :ok

  defp metadata_bound(%{kind: kind, actor: actor, listing_id: id}, %{"id" => id} = metadata)
       when kind in [:create, :update] do
    case Marketplace.validate_metadata(metadata, actor) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_metadata}
    end
  end

  defp metadata_bound(_, _), do: {:error, :invalid_metadata}
  defp hex?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp scope_bytes(scope),
    do: Enum.join([@schema, scope["halaqa_id"], scope["charter_hash"], scope["epoch"]], "\n")

  defp signing_bytes(e),
    do:
      scope_bytes(e) <>
        "\n" <> e["publisher"] <> "\n" <> e["announcement"] <> "\n" <> e["payload"]
end
