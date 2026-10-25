defmodule FederationService.Delivery do
  @moduledoc "Bounded delivery reconciliation of already accepted local public projections."
  alias FederationService.Store
  @batch 32
  @capacity 10_000

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
      |> Enum.sort_by(&elem(&1, 0))
      |> Stream.filter(fn {_, row} -> row.status in [:pending, :held] end)
      |> Stream.map(fn {key, row} -> {key, row, reconcile_row(data, actor, peers, row, now)} end)
      |> Stream.reject(fn {_, old, new} -> old == new end)
      |> Enum.take(@batch + 1)

    selected = Enum.take(updates, @batch)
    budget = @batch - length(selected)
    room = max(0, @capacity - map_size(data.outbox))
    available = min(budget, room)

    candidates =
      data.local
      |> Enum.sort_by(&elem(&1, 0))
      |> Stream.filter(fn {_, source} -> source.actor == actor end)
      |> Stream.flat_map(fn {_, source} ->
        # Activities come only from the durable accepted source projection.
        case data.publications[source.activity_id] do
          nil -> []
          activity -> Enum.map(peers, &new_row(activity, &1, now))
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
      Enum.reduce(selected, %{held: 0, resumed: 0, superseded: 0, settled: 0}, fn {_, _, row},
                                                                                  acc ->
        kind =
          case row.status do
            :held -> :held
            :pending -> :resumed
            :superseded -> :superseded
            :delivered -> :settled
          end

        Map.update!(acc, kind, &(&1 + 1))
      end)

    {changes,
     Map.merge(stats, %{
       inserted: length(inserts),
       more: length(updates) > length(selected) or length(candidates) > length(inserts),
       capacity: room < budget and length(candidates) > length(inserts)
     })}
  end

  defp reconcile_row(data, actor, peers, row, now) do
    case disposition(data, actor, peers, row) do
      :ready when row.status == :held ->
        status = if Map.has_key?(row, :acknowledged_at), do: :delivered, else: :pending
        row |> Map.put(:status, status) |> Map.put(:next_at, now) |> Map.delete(:hold_reason)

      :ready ->
        row

      :superseded ->
        row |> Map.put(:status, :superseded) |> Map.delete(:hold_reason)

      {:held, reason} ->
        row |> Map.put(:status, :held) |> Map.put(:hold_reason, reason)
    end
  end

  defp new_row(activity, destination, now) do
    {{activity["id"], destination},
     %{
       activity: activity,
       destination: destination,
       status: :pending,
       attempts: 0,
       next_at: now
     }}
  end
end
