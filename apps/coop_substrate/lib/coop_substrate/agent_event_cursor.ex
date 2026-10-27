defmodule CoopSubstrate.AgentEventCursor do
  @moduledoc """
  Explicitly invoked STAGING discovery catch-up. Not installed in any supervisor
  or worker. No notification contents are accepted. Bounded read_all pages come
  from the sole Log; the complete observed prefix is audited against its head
  before any discovery registration. A crash repeats from the durable cursor.

  This first increment persists discovery only. It neither drains these effects
  into a backend nor replaces the periodic Coordinator reconciliation. Every
  launch still needs fresh business authorization and its separate SQL lease.
  """
  alias CoopSubstrate.{AgentEventEffects, Log}
  alias CoopSubstrate.Protocol.TypeRegistry
  alias AgentOpsStore.EventCursor

  def catch_up(conn, home, subscriber, host, limit \\ 100)

  def catch_up(conn, home, subscriber, host, limit) when is_integer(limit) and limit in 1..1000 do
    with true <- host.environment() == :staging or {:error, :staging_only},
         {:ok, checkpoint} <- EventCursor.snapshot(conn, home, subscriber),
         head = Log.head(),
         true <- checkpoint.seq <= head.global_seq or {:error, :cursor_ahead_of_ledger},
         :ok <- anchor(checkpoint),
         :ok <- audit(head),
         last = min(head.global_seq, checkpoint.seq + limit),
         {:ok, events} <- Log.read_all(from: checkpoint.seq + 1, as_of: last),
         true <- length(events) == last - checkpoint.seq or {:error, :incomplete_event_page},
         {:ok, bundles, _last} <- AgentEventEffects.page(events, checkpoint, TypeRegistry.types()),
         {:ok, final} <- commit_page(conn, home, subscriber, checkpoint, bundles) do
      {:ok,
       %{
         cursor: final.seq,
         observed_head: head.global_seq,
         caught_up: final.seq == head.global_seq
       }}
    end
  end

  def catch_up(_, _, _, _, _), do: {:error, :invalid_cursor_page_size}

  defp anchor(%{seq: 0, hash: nil}), do: :ok

  defp anchor(%{seq: seq, hash: expected}) do
    with {:ok, ^expected} <- Log.head_at(seq),
         do: :ok,
         else: (_ -> {:error, :cursor_history_mismatch})
  end

  defp audit(%{global_seq: 0, global_hash: nil}), do: :ok

  defp audit(%{global_seq: seq, global_hash: expected}) do
    with :ok <- Log.verify_chains(as_of: seq),
         {:ok, ^expected} <- Log.head_at(seq),
         do: :ok,
         else: (_ -> {:error, :ledger_audit_failed})
  end

  defp commit_page(conn, home, subscriber, checkpoint, bundles) do
    Enum.reduce_while(bundles, {:ok, checkpoint}, fn bundle, {:ok, previous} ->
      case EventCursor.commit(conn, home, subscriber, previous, bundle) do
        {:ok, _} -> {:cont, {:ok, %{seq: bundle.seq, hash: bundle.hash}}}
        error -> {:halt, error}
      end
    end)
  end
end
