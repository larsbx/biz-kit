defmodule FederationService.SubscriptionState do
  @moduledoc """
  Deterministic subscription journal transitions, with no business authority.

  The host MUST verify incoming HTTP signatures, actor identity, explicit peer
  policy and locally authorized approval receipts BEFORE submitting an intent.
  This pure function cannot authenticate either incoming traffic or operators.
  Effects returned here are durable state updates, NOT network deliveries.
  """
  alias FederationCore.Subscriptions, as: Wire
  @max 10_000
  @event_max 20_000
  @max_time 9_007_199_254_740_991

  @doc """
  Recover pre-outbox Follow intents after journal replay, without acknowledging them.

  Active outgoing records retain their exact original Follow. A withdrawn record
  is eligible only to unblock an already journaled, pending Undo; old terminal
  records without retained delivery bytes never generate new effects. Receipts
  must bind the exact payload. Existing effects and relationship rows are untouched.
  The Store must sync all returned changes before exposing the recovered state.
  """
  def recover_outbox(data) do
    data.subscriptions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, [], data}, fn {id, row}, {:ok, changes, current} ->
      if recover_follow?(current, id, row) do
        case outbound(current, row.follow, id, row.started_at) do
          {:ok, {:subscription_outbox, ^id, effect} = change} ->
            current = put_in(current, [:subscription_outbox, id], effect)
            {:cont, {:ok, [change | changes], current}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, changes, current}}
      end
    end)
    |> case do
      {:ok, changes, _} -> {:ok, Enum.reverse(changes)}
      error -> error
    end
  end

  defp recover_follow?(data, id, %{direction: :outgoing} = row) do
    data.subscription_outbox[id] == nil and time(row.started_at) == :ok and
      Wire.follow(row.follower, row.target, id) == {:ok, row.follow} and
      seen(data, row.follow, id) == {:duplicate, {:ok, :duplicate}} and
      (row.status in [:pending, :accepted] or pending_withdrawal?(data, id, row))
  end

  defp recover_follow?(_, _, _), do: false

  defp pending_withdrawal?(data, id, %{status: :withdrawn} = row) do
    Enum.any?(data.subscription_outbox, fn {activity_id, effect} ->
      effect.status == :pending and effect.follow_id == id and
        effect.destination == row.target and
        Wire.undo(row.follower, row.follow, activity_id) == {:ok, effect.activity} and
        seen(data, effect.activity, id) == {:duplicate, {:ok, :duplicate}}
    end)
  end

  defp pending_withdrawal?(_, _, _), do: false

  @doc """
  Plan a finite journal transaction. Never persist rejected or duplicate work.

  :begin and :decide/:cancel are host-only actions. :receive is trusted
  transport input (authenticated actor + local actor), not raw internet JSON.
  """
  def plan(data, {:begin, follow, now}) do
    with :ok <- time(now),
         %{"actor" => follower, "object" => target, "id" => id} <- follow,
         {:ok, ^follow} <- Wire.follow(follower, target, id),
         :ok <- seen(data, follow, id),
         :ok <- pair_available(data, follower, target),
         nil <- data.subscriptions[id] do
      row = %{
        direction: :outgoing,
        follower: follower,
        target: target,
        follow: follow,
        status: :pending,
        started_at: now,
        authority: nil
      }

      record(data, follow, id, row, :begun, now)
    else
      {:duplicate, result} -> {:duplicate, result}
      %{direction: _} -> {:error, :follow_id_exists}
      _ -> {:error, :subscription_begin_refused}
    end
  end

  def plan(data, {:receive, activity, verified_actor, local_actor, now}) do
    with :ok <- time(now),
         {:ok, candidate} <-
           Wire.decode_verified(activity, %{
             verified_actor: verified_actor,
             local_actor: local_actor
           }),
         true <- candidate.authoritative == false do
      case seen(data, activity, candidate.follow_id) do
        :ok -> incoming(data, activity, candidate, now)
        {:duplicate, result} -> {:duplicate, result}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :subscription_receive_refused}
    end
  end

  def plan(data, {:decide, follow_id, decision, activity_id, receipt, now})
      when decision in [:accept, :reject] do
    with :ok <- time(now),
         :ok <- authority_ref(receipt),
         %{direction: :incoming, status: :pending} = row <- data.subscriptions[follow_id],
         {:ok, activity} <- Wire.respond(decision, row.target, row.follow, activity_id) do
      record(
        data,
        activity,
        follow_id,
        %{row | status: decision_status(decision), authority: receipt},
        decision_status(decision),
        now
      )
    else
      _ -> {:error, :subscription_decision_refused}
    end
  end

  def plan(data, {:cancel, follow_id, activity_id, receipt, now}) do
    with :ok <- time(now),
         :ok <- authority_ref(receipt),
         %{direction: :outgoing, status: status} = row <- data.subscriptions[follow_id],
         true <- status in [:pending, :accepted],
         {:ok, activity} <- Wire.undo(row.follower, row.follow, activity_id) do
      record(
        data,
        activity,
        follow_id,
        %{row | status: :withdrawn, authority: receipt},
        :withdrawn,
        now
      )
    else
      _ -> {:error, :subscription_cancel_refused}
    end
  end

  def plan(_, _), do: {:error, :unsupported_subscription_intent}

  defp incoming(data, activity, %{kind: :request} = c, now) do
    with nil <- data.subscriptions[c.follow_id],
         :ok <- pair_available(data, c.follower, c.target) do
      row = %{
        direction: :incoming,
        follower: c.follower,
        target: c.target,
        follow: activity,
        status: :pending,
        started_at: now,
        authority: nil
      }

      record(data, activity, c.follow_id, row, :pending)
    else
      _ -> {:error, :subscription_request_refused}
    end
  end

  defp incoming(data, activity, %{kind: kind} = c, _now)
       when kind in [:accepted, :rejected] do
    with %{direction: :outgoing, status: :pending} = row <- data.subscriptions[c.follow_id],
         true <- row.follower == c.follower and row.target == c.target,
         true <- activity["object"] == row.follow do
      status = kind
      record(data, activity, c.follow_id, %{row | status: status}, status)
    else
      _ -> {:error, :unsolicited_subscription_reply}
    end
  end

  defp incoming(data, activity, %{kind: :withdraw} = c, _now) do
    with %{direction: :incoming, status: status} = row <- data.subscriptions[c.follow_id],
         true <- status in [:pending, :accepted],
         true <- row.follower == c.follower and row.target == c.target,
         true <- activity["object"] == row.follow do
      record(data, activity, c.follow_id, %{row | status: :withdrawn}, :withdrawn)
    else
      _ -> {:error, :subscription_undo_refused}
    end
  end

  defp seen(data, activity, follow_id) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(activity))

    case data.subscription_events[activity["id"]] do
      nil -> :ok
      %{hash: ^hash, follow_id: ^follow_id} -> {:duplicate, {:ok, :duplicate}}
      _ -> {:error, :subscription_activity_conflict}
    end
  end

  defp record(data, activity, follow_id, row, outcome, emit_at \\ nil) do
    id = activity["id"]
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(activity))

    case data.subscription_events[id] do
      %{hash: ^hash, follow_id: ^follow_id} ->
        {:duplicate, {:ok, :duplicate}}

      nil ->
        if (not Map.has_key?(data.subscriptions, follow_id) and
              map_size(data.subscriptions) >= @max) or
             map_size(data.subscription_events) >= @event_max do
          {:error, :subscription_capacity}
        else
          changes = [
            {:subscriptions, follow_id, row},
            {:subscription_events, id, %{hash: hash, follow_id: follow_id}}
          ]

          case outbound(data, activity, follow_id, emit_at) do
            {:ok, effect} ->
              changes = if effect == nil, do: changes, else: changes ++ [effect]
              {:ok, changes, {:ok, outcome}}

            {:error, reason} ->
              {:error, reason}
          end
        end

      _ ->
        {:error, :subscription_activity_conflict}
    end
  end

  defp outbound(_, _, _, nil), do: {:ok, nil}

  defp outbound(data, activity, follow_id, now) do
    id = activity["id"]
    destination = List.first(activity["to"])

    cond do
      map_size(Map.get(data, :subscription_outbox, %{})) >= @max ->
        {:error, :subscription_outbox_capacity}

      Map.get(Map.get(data, :subscription_outbox, %{}), id) != nil ->
        {:error, :subscription_outbox_conflict}

      true ->
        {:ok,
         {:subscription_outbox, id,
          %{
            activity: activity,
            follow_id: follow_id,
            destination: destination,
            status: :pending,
            attempts: 0,
            next_at: now,
            queued_at: now
          }}}
    end
  end

  defp pair_available(data, follower, target) do
    if Enum.any?(data.subscriptions, fn {_id, row} ->
         row.follower == follower and row.target == target and
           row.status in [:pending, :accepted]
       end),
       do: {:error, :relationship_exists},
       else: :ok
  end

  defp decision_status(:accept), do: :accepted
  defp decision_status(:reject), do: :rejected

  defp authority_ref(value) when is_binary(value) and byte_size(value) in 1..256, do: :ok
  defp authority_ref(_), do: {:error, :missing_authority_receipt}

  defp time(n) when is_integer(n) and n >= 0 and n <= @max_time, do: :ok
  defp time(_), do: {:error, :invalid_subscription_time}
end
