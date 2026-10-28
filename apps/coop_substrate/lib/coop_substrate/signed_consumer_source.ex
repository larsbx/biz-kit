defmodule CoopSubstrate.SignedConsumerSource do
  @moduledoc """
  Staging-only read adapter from CoopSubstrate's ONE authoritative EventStore
  log into non-authoritative operational consumers.

  The canonical log's ordinary read_all/1 decodes the stored bytes but does
  NOT re-verify signatures and hash chains on each read. This adapter first
  audits the entire captured signed prefix using Log.verify_chains/1, then
  allows bounded reads ONLY up to that verified position. A new append after
  the audit is not included in the page. The trusted caller must keep the
  captured head and refuse a page containing a sequence gap or reordering.

  This operation may be expensive for a large ledger: prefix verification is
  O(history). A later production optimization can use independently anchored
  signed checkpoints plus a proven incremental chain audit; it must not
  weaken this initial fail-closed trust boundary.

  It grants no task, agent, read, tool, business-write or payment authority.
  External ActivityPub events are NOT accepted by this adapter.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @doc "Return the exact signed and hash-chain-verified current global head."
  def verified_head do
    seq = Log.head().global_seq

    case Log.verify_chains(as_of: seq) do
      :ok -> {:ok, seq}
      {:error, _} -> {:error, :unverified_ledger_prefix}
    end
  rescue
    _ -> {:error, :ledger_source_unavailable}
  catch
    :exit, _ -> {:error, :ledger_source_unavailable}
  end

  @doc "Read an inclusive bounded page from the previously verified prefix."
  def read_page(first, last)
      when is_integer(first) and is_integer(last) and first > 0 and last >= first and
             last - first < 100 do
    case Log.read_all(from: first, as_of: last) do
      {:ok, events} when is_list(events) -> {:ok, events}
      _ -> {:error, :ledger_source_unavailable}
    end
  rescue
    _ -> {:error, :ledger_source_unavailable}
  catch
    :exit, _ -> {:error, :ledger_source_unavailable}
  end

  def read_page(_first, _last), do: {:error, :invalid_ledger_page}

  @doc "Hash the canonical full recorded envelope, including accepted chain placement."
  def event_digest(%Envelope{} = event), do: Envelope.event_hash(event)
  def event_digest(_event), do: {:error, :not_a_signed_ledger_envelope}
end
