defmodule FederationService.SubscriptionDelivery do
  @moduledoc """
  Durable at-least-once signed ActivityPub control-message delivery.

  All payloads originate from accepted local subscription journal intents.
  Only explicitly configured remote peers are eligible; no recursive
  follower expansion and no business commands are made.
  """
  alias FederationService.{Network, Signature, Store, SubscriptionAuthority}
  @batch 8

  def deliver(config, now \\ System.system_time(:second)) do
    snapshot = Store.call(config.store, :snapshot)

    snapshot.subscription_outbox
    |> Enum.filter(fn {_id, row} ->
      row.status == :pending and row.next_at <= now and
        ready?(snapshot, config, row)
    end)
    |> Enum.sort_by(fn {id, row} -> {row.queued_at, priority(row.activity), id} end)
    |> Enum.take(@batch)
    |> Enum.each(fn {id, row} ->
      if ready?(Store.call(config.store, :snapshot), config, row) do
        result =
          with {:ok, remote} <- Signature.discover(row.destination, config.network),
               body <- Jason.encode!(row.activity),
               headers <- Signature.sign(remote.inbox, config.actor, config.private_key, body),
               {:ok, outcome} <- authorized_post(config, row, remote.inbox, headers, body) do
            outcome
          else
            {:error, :unverified_local_authority} -> :held
            false -> :held
            _ -> false
          end

        if is_boolean(result) do
          Store.call(config.store, {:subscription_delivery, id, result, now})
        end
      end
    end)
  end

  defp authorized_post(config, row, inbox, headers, body) do
    effect = fn ->
      if ready?(Store.call(config.store, :snapshot), config, row) do
        case Network.request(:post, inbox, headers, body, config.network) do
          {:ok, status, _, _} -> status in [200, 202]
          _ -> false
        end
      else
        :held
      end
    end

    case row.activity["type"] do
      "Follow" ->
        {:ok, effect.()}

      type when type in ["Accept", "Reject", "Undo"] ->
        relation = Store.call(config.store, :snapshot).subscriptions[row.follow_id]
        operation = %{"Accept" => :accept, "Reject" => :reject, "Undo" => :undo}[type]

        SubscriptionAuthority.run(
          config,
          row.follow_id,
          operation,
          relation.authority,
          row.activity["id"],
          effect
        )
    end
  end

  @doc "A live policy and correlation check; never licenses an unrelated activity."
  def ready?(
        data,
        config,
        %{activity: activity, destination: destination, follow_id: follow_id} = row
      ) do
    relation = data.subscriptions[follow_id]

    cond do
      row.status != :pending or data.subscription_outbox[activity["id"]] != row ->
        false

      activity["actor"] != config.actor or destination not in config.peers ->
        false

      Store.blocked?(data, destination, "") ->
        false

      relation == nil ->
        false

      activity["type"] in ["Accept", "Reject"] and
          relation.follower != List.first(activity["to"]) ->
        false

      activity["type"] == "Follow" ->
        relation.direction == :outgoing and relation.follow == activity and
          relation.status in [:pending, :accepted, :withdrawn]

      activity["type"] == "Accept" ->
        relation.direction == :incoming and relation.status == :accepted and
          relation.target == config.actor and relation.follower == destination and
          activity["object"] == relation.follow

      activity["type"] == "Reject" ->
        relation.direction == :incoming and relation.status == :rejected and
          relation.target == config.actor and relation.follower == destination and
          activity["object"] == relation.follow

      activity["type"] == "Undo" ->
        first = data.subscription_outbox[follow_id]

        relation.direction == :outgoing and relation.status == :withdrawn and
          relation.target == destination and activity["object"] == relation.follow and
          first != nil and first.status == :delivered

      true ->
        false
    end
  end

  def ready?(_, _, _), do: false

  defp priority(%{"type" => "Follow"}), do: 0
  defp priority(_), do: 1
end
