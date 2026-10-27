defmodule AgentOpsStore.EventCursor do
  @moduledoc """
  Privileged, operational cursor/bundle registration in the governed database.

  This is NOT a business event consumer, dispatcher or authority gate. The
  caller MUST obtain the event from the already verified signed
  CoopSubstrate.Log API, bind its immutable event hash and scope to the
  locally configured home, and determine the complete effect bundle with
  trusted rules. The function cannot verify an EventStore append.

  All registered effects are NON-EXECUTABLE operational candidates. An
  independent coordinator must recheck current signed read/execute grants,
  approved profile and consent before doing work or exposing data.

  004_event_cursor.sql stores the entire immutable bundle, a processed
  receipt (including for empty bundles), and the new cursor in one locked
  PostgreSQL transaction. A duplicate matching event is idempotent.
  """

  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @max_effects 16

  @doc """
  Commit one complete trusted event bundle at the NEXT accepted sequence.

  `event` is a trusted descriptor with:
  * home_id, consumer_id: configured business home/consumer identifiers;
  * global_seq: one-based canonical ledger sequence, never from notification;
  * event_id, event_digest: accepted canonical event identity/hash;
  * effects: complete list of %{effect_id: ..., kind: ...}.

  A successful return does not imply the agent or any business effect ran.
  """
  @spec commit(pid() | atom(), map()) ::
          {:ok, %{cursor: pos_integer(), disposition: :new | :existing}}
          | {:error, atom()}
  def commit(conn, event) when is_map(event) do
    with {:ok, params} <- parameters(event),
         {:ok, %Postgrex.Result{rows: [[cursor, disposition]]}} <-
           Postgrex.query(
             conn,
             "SELECT ack_seq, disposition FROM agent_ops.commit_event_bundle($1,$2,$3,$4,$5,$6::text::jsonb)",
             params
           ) do
      {:ok, %{cursor: cursor, disposition: disposition(disposition)}}
    else
      {:error, :invalid_event_bundle} = invalid -> invalid
      {:error, _} -> {:error, :event_cursor_transaction_refused}
      _ -> {:error, :event_cursor_transaction_refused}
    end
  rescue
    _ -> {:error, :event_cursor_store_unavailable}
  catch
    :exit, _ -> {:error, :event_cursor_store_unavailable}
  end

  def commit(_conn, _event), do: {:error, :invalid_event_bundle}

  @doc "Read the last committed watermark, without granting event authority."
  def watermark(conn, home, consumer) do
    if segment?(home) and segment?(consumer) do
      case Postgrex.query(
             conn,
             "SELECT last_seq FROM agent_ops.consumer_cursors WHERE home_id=$1 AND consumer_id=$2",
             [home, consumer]
           ) do
        {:ok, %Postgrex.Result{rows: [[seq]]}} -> {:ok, seq}
        {:ok, %Postgrex.Result{rows: []}} -> {:ok, 0}
        {:error, _} -> {:error, :event_cursor_store_unavailable}
      end
    else
      {:error, :invalid_event_cursor_scope}
    end
  rescue
    _ -> {:error, :event_cursor_store_unavailable}
  catch
    :exit, _ -> {:error, :event_cursor_store_unavailable}
  end

  defp parameters(%{
         home_id: home,
         consumer_id: consumer,
         global_seq: seq,
         event_id: event,
         event_digest: {:bytes, <<_::256>> = digest},
         effects: effects
       }) do
    with true <- segment?(home) and segment?(consumer) and segment?(event),
         true <- is_integer(seq) and seq > 0,
         true <- valid_effects?(effects),
         {:ok, encoded} <- Jason.encode(Enum.map(effects, &encode_effect/1)),
         true <- byte_size(encoded) <= 8192 do
      {:ok, [home, consumer, seq, event, digest, encoded]}
    else
      _ -> {:error, :invalid_event_bundle}
    end
  end

  defp parameters(_), do: {:error, :invalid_event_bundle}

  defp valid_effects?(effects) when is_list(effects) and length(effects) <= @max_effects do
    ids = Enum.map(effects, fn
      %{effect_id: id} -> id
      _ -> nil
    end)

    Enum.all?(effects, fn
      %{effect_id: id, kind: kind} = item ->
        map_size(item) == 2 and segment?(id) and segment?(kind)

      _ ->
        false
    end) and length(Enum.uniq(ids)) == length(ids)
  end

  defp valid_effects?(_), do: false
  defp encode_effect(%{effect_id: id, kind: kind}),
    do: %{"effect_id" => id, "kind" => kind}

  defp disposition("new"), do: :new
  defp disposition("existing"), do: :existing

  defp segment?(value), do: is_binary(value) and Regex.match?(@segment, value)
end
