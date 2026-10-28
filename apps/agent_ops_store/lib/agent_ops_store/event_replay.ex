defmodule AgentOpsStore.EventReplay do
  @moduledoc """
  Opt-in STAGING ONLY consumer of committed, signed CoopSubstrate events.

  This module is neither the business writer nor an agent executor. It drains
  at most one bounded verified ledger page, maps accepted events through a
  reviewed host policy, and atomically commits non-executable operational
  candidates, processed receipts (including no-op events) and the durable
  checkpoint through EventCursor's PostgreSQL CAS.

  A trusted host supplies the authenticated local home, consumer identifier,
  signed-ledger source adapter and an EXPLICIT reviewed no-op type allowlist.
  Neither :pg notifications, remote/federated events nor agent arguments may
  choose those values. Every invocation revalidates the signed source head;
  missed notifications are safe because the persisted cursor is the only
  progress marker. No input on this API is a business authorization.
  """

  alias AgentOpsStore.{EventCursor, EventEffects}

  @default_page 25

  @doc "Consume at most one bounded page, preserving cursor+bundle atomicity."
  @spec drain(pid() | atom(), module(), keyword()) ::
          {:ok,
           %{
             from: non_neg_integer(),
             to: non_neg_integer(),
             processed: non_neg_integer(),
             has_more: boolean()
           }}
          | {:error, atom()}
  def drain(conn, host, opts \\ []) when is_list(opts) do
    with :ok <- staging(host),
         {:ok, max_events} <- max_events(opts),
         {:ok, %{home_id: home, consumer_id: consumer, source: source, ignored_types: ignored}} <-
           host.event_consumer_context(),
         :ok <- validate_context(home, consumer, source, ignored),
         {:ok, cursor} <- EventCursor.watermark(conn, home, consumer),
         {:ok, head} <- source.verified_head(),
         :ok <- valid_head(head, cursor) do
      upper = min(head, cursor + max_events)

      if upper == cursor do
        {:ok, %{from: cursor, to: cursor, processed: 0, has_more: false}}
      else
        with {:ok, events} <- source.read_page(cursor + 1, upper),
             :ok <- contiguous(events, cursor + 1, upper),
             {:ok, result} <- process_page(conn, source, home, consumer, ignored, events) do
          {:ok, %{from: cursor, to: result, processed: result - cursor, has_more: result < head}}
        end
      end
    end
  rescue
    _ -> {:error, :trusted_replay_unavailable}
  catch
    :exit, _ -> {:error, :trusted_replay_unavailable}
  end

  def drain(_conn, _host, _opts), do: {:error, :invalid_event_replay_options}

  defp staging(host) when is_atom(host) do
    if function_exported?(host, :environment, 0) and host.environment() == :staging and
         function_exported?(host, :event_consumer_context, 0),
       do: :ok,
       else: {:error, :staging_only}
  end

  defp staging(_host), do: {:error, :staging_only}

  defp max_events(opts) do
    limit = Keyword.get(opts, :max_events, @default_page)

    if is_integer(limit) and limit in 1..100,
      do: {:ok, limit},
      else: {:error, :invalid_replay_page_limit}
  end

  defp validate_context(home, consumer, source, ignored) do
    valid_id = fn x ->
      is_binary(x) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/, x)
    end

    cond do
      not valid_id.(home) or not valid_id.(consumer) ->
        {:error, :invalid_event_cursor_scope}

      not is_atom(source) or not Code.ensure_loaded?(source) or
          not Enum.all?([verified_head: 0, read_page: 2, event_digest: 1], fn {f, a} ->
            function_exported?(source, f, a)
          end) ->
        {:error, :unapproved_event_source}

      not is_list(ignored) or not Enum.all?(ignored, valid_id) ->
        {:error, :invalid_ignored_event_types}

      true ->
        :ok
    end
  end

  defp valid_head(head, cursor)
       when is_integer(head) and is_integer(cursor) and head >= cursor and cursor >= 0,
       do: :ok

  defp valid_head(_head, _cursor), do: {:error, :ledger_cursor_ahead_of_verified_head}

  # Detect missing positions, duplicates, out-of-order pages and incomplete
  # reads BEFORE the first SQL commit. A temporary read gap is never a no-op.
  defp contiguous(events, first, last) when is_list(events) do
    expected = Enum.to_list(first..last)

    received =
      Enum.map(events, fn
        %{global_seq: n} -> n
        _ -> :invalid
      end)

    if received == expected, do: :ok, else: {:error, :ledger_read_gap_or_reorder}
  end

  defp contiguous(_events, _first, _last), do: {:error, :ledger_read_gap_or_reorder}

  defp process_page(conn, source, home, consumer, ignored, events) do
    Enum.reduce_while(events, {:ok, nil}, fn event, _previous ->
      with {:ok, <<_::256>> = digest} <- source.event_digest(event),
           {:ok, effects} <- EventEffects.derive(event, ignored_types: ignored),
           {:ok, %{cursor: seq}} <-
             EventCursor.commit(conn, %{
               home_id: home,
               consumer_id: consumer,
               global_seq: event.global_seq,
               event_id: event.event_id,
               event_digest: {:bytes, digest},
               effects: effects
             }) do
        {:cont, {:ok, seq}}
      else
        {:error, reason} when is_atom(reason) -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_trusted_ledger_event}}
      end
    end)
  end
end
