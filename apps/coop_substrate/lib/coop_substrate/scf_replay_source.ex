defmodule CoopSubstrate.ScfReplaySource do
  @moduledoc """
  Bounded, read-only capture for an operator-run SCF replay. The source is the
  local canonical log. The resulting rows contain private business data and
  are intended for an authorized internal caller.
  """

  alias CoopSubstrate.{Log, SignedConsumerSource}
  alias CoopSubstrate.Protocol.Envelope

  @max_records 10_000
  @page_size 100

  @doc "Audit and capture the current prefix, subject to the requested record limit."
  def capture(limit) when is_integer(limit) and limit in 1..@max_records do
    head = Log.head()

    with :ok <- within_limit(head.global_seq, limit),
         :ok <- audit(head.global_seq) do
      read_prefix(head, &SignedConsumerSource.read_page/2)
    end
  rescue
    _ -> {:error, :ledger_source_unavailable}
  catch
    :exit, _ -> {:error, :ledger_source_unavailable}
  end

  def capture(_), do: {:error, :invalid_capture_limit}

  defp within_limit(sequence, limit) when sequence <= limit, do: :ok
  defp within_limit(_, _), do: {:error, :capture_limit_exceeded}

  defp audit(sequence) do
    case Log.verify_chains(as_of: sequence) do
      :ok -> :ok
      {:error, _} -> {:error, :unverified_ledger_prefix}
    end
  end

  @doc false
  # The caller must supply the previously audited canonical head. Linking
  # every page back to genesis and comparing the final digest binds the
  # returned records to that head even if the store changes after the audit.
  def read_prefix(%{global_seq: sequence, global_hash: digest}, read_page) do
    with {:ok, reversed, ^digest} <- pages(1, sequence, nil, [], read_page) do
      {:ok, %{head: %{sequence: sequence, digest: digest}, rows: Enum.reverse(reversed)}}
    else
      {:ok, _, _} -> {:error, :ledger_head_mismatch}
      {:error, _} = error -> error
    end
  end

  defp pages(first, last, previous, rows, _) when first > last, do: {:ok, rows, previous}

  defp pages(first, last, previous, rows, read_page) do
    page_end = min(first + @page_size - 1, last)

    with {:ok, events} <- read_page.(first, page_end),
         {:ok, next, digest} <- fold_page(events, first, page_end, previous, rows) do
      pages(page_end + 1, last, digest, next, read_page)
    end
  end

  defp fold_page([], sequence, last, previous, rows) when sequence == last + 1,
    do: {:ok, rows, previous}

  defp fold_page(
         [%Envelope{global_seq: sequence, prev_global_hash: previous} = event | rest],
         sequence,
         last,
         previous,
         rows
       )
       when sequence <= last do
    with {:ok, digest} <- SignedConsumerSource.event_digest(event) do
      ref = %{
        sequence: sequence,
        digest: digest,
        event_id: event.event_id,
        chapter: event.chapter_id,
        stream_id: event.stream_id,
        stream_sequence: event.stream_seq,
        type: event.type
      }

      row = %{ref: ref, payload: normalize(event.type, event.payload)}
      fold_page(rest, sequence + 1, last, digest, [row | rows])
    end
  end

  defp fold_page(_, _, _, _, _), do: {:error, :invalid_ledger_page}

  defp normalize("ScfServiceRevenueRecognizedV1", payload) do
    payload
    |> unwrap("invoice", "digest")
    |> unwrap("document", "sha256")
  end

  defp normalize("ScfEntryReversedV1", payload) do
    payload
    |> unwrap("target", "digest")
    |> unwrap("document", "sha256")
  end

  defp normalize("ScfFiscalYearClosedV1", payload), do: unwrap(payload, "document", "sha256")
  defp normalize(_, payload), do: payload

  defp unwrap(payload, parent, field) do
    case payload[parent] do
      %{^field => {:bytes, bytes}} = nested ->
        Map.put(payload, parent, %{nested | field => bytes})

      %{} = nested ->
        Map.put(payload, parent, Map.delete(nested, field))

      _ ->
        payload
    end
  end
end
