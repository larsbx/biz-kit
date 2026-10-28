defmodule FederationService.Delivery do
  @moduledoc "Bounded delivery reconciliation of already accepted local public projections."
  alias FederationService.Store
  @batch 32
  @capacity 10_000

  def generation(data, actor, peer) do
    case Map.get(Map.get(data, :redeliveries, %{}), peer) do
      %{actor: ^actor, generation: generation} -> generation
      _ -> 0
    end
  end

  def ready?(data, actor, peers, row),
    do:
      Map.get(row, :generation, 0) == generation(data, actor, row.destination) and
        disposition(data, actor, peers, row) == :ready

  @doc "Current source and moderation decision; never derives business authority."
  def disposition(data, actor, peers, row) do
    activity = row.activity
    id = activity["object"]["id"]
    source = data.local[id]

    cond do
      activity["actor"] != actor ->
        {:held, :actor_mismatch}

      source == nil ->
        {:held, :missing_source}

      source.actor != actor ->
        {:held, :actor_mismatch}

      source.activity_id != activity["id"] ->
        :superseded

      row.destination not in peers ->
        {:held, :peer_removed}

      Store.blocked?(data, row.destination, "") ->
        {:held, :peer_blocked}

      activity["type"] != "Delete" and Store.blocked?(data, actor, id) ->
        {:held, :listing_blocked}

      true ->
        :ready
    end
  end

  @doc "At most 32 changes per transaction; receipts and activity IDs are retained."
  def plan(data, actor, peers, now) do
    updates =
      data.outbox
      |> Enum.sort_by(fn {key, row} ->
        {if(row.activity["type"] == "Delete", do: 0, else: 1), key}
      end)
      |> Stream.filter(fn {_, row} ->
        row.status in [:pending, :held] or
          (row.status == :delivered and
             Map.get(row, :generation, 0) != generation(data, actor, row.destination))
      end)
      |> Stream.map(fn {key, row} -> {key, row, reconcile_row(data, actor, peers, row, now)} end)
      |> Stream.reject(fn {_, old, new} -> old == new end)
      |> Enum.take(@batch + 1)

    selected = Enum.take(updates, @batch)
    budget = @batch - length(selected)
    room = max(0, @capacity - map_size(data.outbox))
    available = min(budget, room)

    candidates =
      data.local
      |> Enum.sort_by(fn {id, source} ->
        {if(source.withdrawn, do: 0, else: 1), id}
      end)
      |> Stream.filter(fn {_, source} -> source.actor == actor end)
      |> Stream.flat_map(fn {_, source} ->
        # Activities come only from the durable accepted source projection.
        case data.publications[source.activity_id] do
          nil -> []
          activity -> Enum.map(peers, &new_row(activity, &1, generation(data, actor, &1), now))
        end
      end)
      |> Stream.reject(fn {key, _} -> Map.has_key?(data.outbox, key) end)
      |> Stream.filter(fn {_, row} -> disposition(data, actor, peers, row) == :ready end)
      |> Enum.take(available + 1)

    inserts = Enum.take(candidates, available)

    changes =
      Enum.map(selected, fn {key, _, row} -> {:outbox, key, row} end) ++
        Enum.map(inserts, fn {key, row} -> {:outbox, key, row} end)

    stats =
      Enum.reduce(selected, %{held: 0, resumed: 0, superseded: 0, settled: 0, requeued: 0}, fn {_,
                                                                                                old,
                                                                                                row},
                                                                                               acc ->
        kind =
          case row.status do
            :held -> :held
            :pending -> :resumed
            :superseded -> :superseded
            :delivered -> :settled
          end

        acc = Map.update!(acc, kind, &(&1 + 1))

        if Map.get(old, :generation, 0) != Map.get(row, :generation, 0),
          do: Map.update!(acc, :requeued, &(&1 + 1)),
          else: acc
      end)

    {changes,
     Map.merge(stats, %{
       inserted: length(inserts),
       more: length(updates) > length(selected) or length(candidates) > length(inserts),
       capacity: room < budget and length(candidates) > length(inserts)
     })}
  end

  defp reconcile_row(data, actor, peers, row, now) do
    wanted = generation(data, actor, row.destination)
    decision = disposition(data, actor, peers, row)

    row =
      if decision != :superseded and row.activity["actor"] == actor and
           Map.get(row, :generation, 0) != wanted do
        row
        |> Map.merge(%{generation: wanted, status: :pending, attempts: 0, next_at: now})
        |> Map.delete(:hold_reason)
      else
        row
      end

    case decision do
      :ready when row.status == :held ->
        acknowledged =
          Map.has_key?(row, :acknowledged_at) and
            Map.get(row, :acknowledged_generation, 0) == Map.get(row, :generation, 0)

        status = if acknowledged, do: :delivered, else: :pending
        row |> Map.put(:status, status) |> Map.put(:next_at, now) |> Map.delete(:hold_reason)

      :ready ->
        row

      :superseded ->
        row |> Map.put(:status, :superseded) |> Map.delete(:hold_reason)

      {:held, reason} ->
        row |> Map.put(:status, :held) |> Map.put(:hold_reason, reason)
    end
  end

  defp new_row(activity, destination, generation, now) do
    {{activity["id"], destination},
     %{
       activity: activity,
       destination: destination,
       generation: generation,
       status: :pending,
       attempts: 0,
       next_at: now
     }}
  end
end
