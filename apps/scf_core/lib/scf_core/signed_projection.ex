defmodule ScfCore.SignedProjection do
  @moduledoc """
  Offline SCF fold over normalized records from one trusted, audited canonical
  log prefix, starting at global sequence 1. See SIGNED_PROJECTION.md for the
  source contract. This module has no event admission or persistence interface.
  """

  alias ScfCore.Ledger

  defstruct ledger: %Ledger{},
            sequence: 0,
            records: %{},
            invoices: %{},
            recognized: %{},
            postings: %{},
            reversed: MapSet.new(),
            open_year: nil

  @doc """
  Rebuild one chapter/entity book. Input rows are an internal replay contract,
  never a public ingest format. An error identifies the failing log position
  and returns no partial book.
  """
  def replay(records, %{chapter: chapter, entity: entity, first_year: year} = book)
      when is_list(records) and is_binary(chapter) and chapter != "" and
             is_binary(entity) and entity != "" and year in 1..9998 do
    Enum.reduce_while(records, {:ok, %__MODULE__{open_year: year}}, fn row, {:ok, state} ->
      case step(state, book, row) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def replay(_, _), do: {:error, :invalid_book_or_history}

  defp step(state, book, %{ref: ref, payload: payload} = row) when is_map(payload) do
    with :ok <- validate_ref(ref) do
      seq = ref.sequence

      case Map.fetch(state.records, seq) do
        {:ok, ^row} ->
          {:ok, state}

        {:ok, _} ->
          {:error, {seq, :source_conflict}}

        :error when seq == state.sequence + 1 ->
          case project(state, book, ref, payload) do
            {:ok, next} ->
              {:ok, %{next | sequence: seq, records: Map.put(state.records, seq, row)}}

            {:error, reason} ->
              {:error, {seq, reason}}
          end

        :error ->
          {:error, {seq, :source_gap}}
      end
    end
  end

  defp step(_, _, _), do: {:error, :invalid_source}

  defp validate_ref(%{
         sequence: seq,
         digest: <<_::256>>,
         event_id: id,
         chapter: chapter,
         stream_id: stream,
         stream_sequence: revision,
         type: type
       })
       when is_integer(seq) and seq > 0 and is_integer(revision) and revision > 0 and
              is_binary(id) and id != "" and is_binary(chapter) and chapter != "" and
              is_binary(stream) and stream != "" and is_binary(type) and type != "",
       do: :ok

  defp validate_ref(_), do: {:error, :invalid_source}

  defp project(
         state,
         %{chapter: chapter, entity: entity},
         %{chapter: chapter} = ref,
         %{
           "entity_id" => entity
         } = payload
       ) do
    case ref.type do
      "InvoiceIssued" ->
        {:ok, put_in(state.invoices[ref.sequence], {ref, payload})}

      "ScfServiceRevenueRecognizedV1" ->
        recognize(state, ref, payload)

      "ScfEntryReversedV1" ->
        reverse(state, ref, payload)

      "ScfFiscalYearClosedV1" ->
        close_year(state, payload)

      _ ->
        {:ok, state}
    end
  end

  defp project(state, %{chapter: chapter}, %{chapter: chapter, type: type}, payload)
       when type in [
              "ScfServiceRevenueRecognizedV1",
              "ScfEntryReversedV1",
              "ScfFiscalYearClosedV1"
            ] do
    case payload do
      %{"entity_id" => entity} when is_binary(entity) and entity != "" -> {:ok, state}
      _ -> {:error, :missing_entity}
    end
  end

  defp project(state, _, _, _), do: {:ok, state}

  defp recognize(state, ref, payload) do
    with {:ok, invoice_ref, invoice_id, amount} <- invoice(state, payload["invoice"]),
         :ok <- unused(state.recognized, invoice_id, :invoice_already_recognized),
         :ok <- dzd(payload["currency"]),
         :ok <- no_tva(payload["tva_treatment"]),
         {:ok, attrs, document} <- entry_attrs(state, ref, payload),
         {:ok, ledger} <-
           Ledger.post(
             state.ledger,
             Map.merge(attrs, %{
               journal: "VE",
               lines: [{:debit, "411", amount}, {:credit, "706", amount}]
             })
           ) do
      posting = %{source: ref, invoice: invoice_ref, document: document, reverses: nil}
      next = %{state | ledger: ledger}
      next = put_in(next.postings[ref.sequence], posting)
      {:ok, put_in(next.recognized[invoice_id], ref.sequence)}
    end
  end

  defp invoice(state, %{"sequence" => seq, "digest" => digest}) do
    case state.invoices[seq] do
      {%{digest: ^digest} = ref, %{"invoice_id" => id, "amount_minor" => amount}}
      when is_binary(id) and id != "" and is_integer(amount) and amount > 0 ->
        {:ok, ref, id, amount}

      _ ->
        {:error, :missing_invoice_evidence}
    end
  end

  defp invoice(_, _), do: {:error, :missing_invoice_evidence}

  defp reverse(state, ref, payload) do
    with {:ok, target} <- reversal_target(state, payload["target"]),
         :ok <- dzd(payload["currency"]),
         {:ok, attrs, document} <- entry_attrs(state, ref, payload),
         target_id = entry_id(target.source),
         :ok <- on_or_after(attrs.date, state.ledger.entries[target_id].date),
         {:ok, ledger} <- Ledger.reverse(state.ledger, target_id, attrs) do
      posting = %{
        source: ref,
        invoice: target.invoice,
        document: document,
        reverses: target.source
      }

      next = %{
        state
        | ledger: ledger,
          reversed: MapSet.put(state.reversed, target.source.sequence)
      }

      {:ok, put_in(next.postings[ref.sequence], posting)}
    end
  end

  defp reversal_target(state, %{"sequence" => seq, "digest" => digest}) do
    case state.postings[seq] do
      %{source: %{digest: ^digest}} = posting ->
        if MapSet.member?(state.reversed, seq),
          do: {:error, :entry_already_reversed},
          else: {:ok, posting}

      _ ->
        {:error, :missing_reversal_target}
    end
  end

  defp reversal_target(_, _), do: {:error, :missing_reversal_target}

  defp close_year(state, %{"through" => value, "document" => document}) when is_binary(value) do
    with {:ok, _} <- supporting_document(document),
         {:ok, date} <- Date.from_iso8601(value),
         {:ok, year_end} <- Date.new(state.open_year, 12, 31),
         :ok <- exact_close(date, year_end),
         {:ok, ledger} <- Ledger.close(state.ledger, date) do
      {:ok, %{state | ledger: ledger, open_year: state.open_year + 1}}
    end
  end

  defp close_year(_, _), do: {:error, :invalid_fiscal_close}
  defp exact_close(date, date), do: :ok
  defp exact_close(_, _), do: {:error, :invalid_fiscal_close}

  defp entry_attrs(state, ref, payload) do
    with {:ok, date} <- open_date(payload["date"], state.open_year),
         {:ok, document} <- supporting_document(payload["document"]) do
      {:ok, %{id: entry_id(ref), date: date, piece: document["id"]}, document}
    end
  end

  defp supporting_document(%{"id" => id, "sha256" => <<_::256>>} = document)
       when is_binary(id) and id != "" do
    if String.trim(id) == "", do: {:error, :missing_document}, else: {:ok, document}
  end

  defp supporting_document(_), do: {:error, :missing_document}

  defp open_date(value, year) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: ^year} = date} -> {:ok, date}
      {:ok, _} -> {:error, :outside_open_fiscal_year}
      {:error, _} -> {:error, :invalid_accounting_date}
    end
  end

  defp open_date(_, _), do: {:error, :invalid_accounting_date}
  defp dzd("DZD"), do: :ok
  defp dzd(_), do: {:error, :unsupported_currency}
  defp no_tva("no_tva"), do: :ok
  defp no_tva(_), do: {:error, :unsupported_tva_treatment}

  defp on_or_after(date, target) do
    if Date.before?(date, target), do: {:error, :reversal_before_target}, else: :ok
  end

  defp unused(index, key, error) do
    if Map.has_key?(index, key), do: {:error, error}, else: :ok
  end

  defp entry_id(ref), do: "signed-scf-v1:" <> Integer.to_string(ref.sequence)
end
