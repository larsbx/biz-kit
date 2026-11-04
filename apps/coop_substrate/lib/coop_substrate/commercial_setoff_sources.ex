defmodule CoopSubstrate.CommercialSetoffSources do
  @moduledoc """
  Inert source-event extraction for commercial setoff proof proposals.

  Reads the source-owning canonical **business** log, not federation adverts
  or user-supplied invoice IDs. Each returned source carries the authenticated
  original ObligationRecorded event's version and full-record hash.

  This V1 bridge deliberately REFUSES assigned/revised source histories.
  Current business obligations do not yet carry an authoritative source
  revision, an independently validated trade contract, or commercial
  discharge eligibility. Neither this snapshot nor CommercialSetoffProof
  can authorize a new ledger append or certify a legal settlement.

  This is a read-only evidence convenience, not an atomic source fence.
  The future serialized append gate must revalidate all sources and grants.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Protocol.TypeRegistry

  @max_sources 256

  @doc """
  Derive source terms for CommercialSetoffProof.prepare/8 from the current
  single-node signed ledger. The caller must use the same returned gate
  and source terms to construct an inert proof proposal.

  A concurrent writer, failed global hash-chain audit, non-original source
  history, absent source, invalid signature, or inconsistent fold fails closed.
  """
  def snapshot(chapter, pair, denomination, server \\ Log.server())

  def snapshot(chapter, {a, b}, denomination, server)
      when is_binary(chapter) and chapter != "" and
             is_binary(a) and is_binary(b) and a < b and
             is_binary(denomination) and denomination != "" do
    head_before = Log.head(server)
    gate = Log.gate(server)

    with :ok <- Log.verify_chains(),
         {:ok, rows} <- current_rows(gate, chapter, {a, b}, denomination),
         {:ok, sources} <- source_terms(rows, chapter),
         ^head_before <- Log.head(server) do
      {:ok,
       %{
         gate: gate,
         sources: sources,
         observed_head: head_before,
         source_status: :locally_signed_business_history,
         agency_status: :unverified,
         legal_status: :unverified,
         admission: :not_authorized,
         settlement: :none
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :concurrent_ledger_change}
    end
  end

  def snapshot(_, _, _, _), do: {:error, :invalid_request}

  @doc """
  Read-only verification against freshly authenticated local source history.

  Never accept caller-supplied source rows as a substitute for the canonical
  local business log when checking source-binding. This operation re-reads
  signed sources and checks that the observed head remains unchanged through
  verification. A later concurrent append remains possible: this is NOT
  an admission fence, source reservation or legally effective discharge.

  Agency grants and legal references remain independently unverified; neither
  keys nor signatures establish a participant's authority to bind an entity.
  """
  def verify_local(proof, grants, signatures, spent \\ MapSet.new(), server \\ Log.server())

  def verify_local(%{body: %{} = body} = proof, grants, signatures, spent, server) do
    with {:ok, %{observed_head: head} = snapshot} <-
           snapshot(
             body["chapter_id"],
             {body["party_a"], body["party_b"]},
             body["denomination"],
             server
           ),
         {:ok, result} <-
           CoopSubstrate.CommercialSetoffProof.verify(
             proof,
             snapshot.gate,
             snapshot.sources,
             grants,
             signatures,
             spent
           ),
         ^head <- Log.head(server) do
      {:ok,
       Map.merge(result, %{
         source_status: :locally_signed_business_history,
         observed_head: head,
         agency_status: :unverified,
         legal_status: :unverified
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :concurrent_ledger_change}
    end
  end

  def verify_local(_, _, _, _, _), do: {:error, :invalid_verification_request}

  defp current_rows(%{obligations: obligations}, chapter, {a, b}, denomination)
       when is_map(obligations) do
    rows =
      obligations
      |> Enum.filter(fn
        {{^chapter, _id}, %{open: true, denomination: ^denomination} = ob} ->
          {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}]

        _ ->
          false
      end)
      |> Enum.sort_by(fn {{_chapter, id}, _row} -> id end)

    cond do
      length(rows) < 2 -> {:error, :no_bilateral_sources}
      length(rows) > @max_sources -> {:error, :source_limit_exceeded}
      not Enum.any?(rows, fn {_id, row} -> row.debtor_id == a end) ->
        {:error, :no_bilateral_sources}

      not Enum.any?(rows, fn {_id, row} -> row.debtor_id == b end) ->
        {:error, :no_bilateral_sources}

      true -> {:ok, rows}
    end
  end

  defp current_rows(_, _, _, _), do: {:error, :invalid_gate}

  defp source_terms(rows, chapter) do
    Enum.reduce_while(rows, {:ok, []}, fn {{_chapter, id}, row}, {:ok, sources} ->
      case source_term(chapter, id, row) do
        {:ok, source} -> {:cont, {:ok, [source | sources]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp source_term(chapter, id, row) do
    with {:ok, stream} <-
           TypeRegistry.stream_id("ObligationRecorded", chapter, %{"obligation_id" => id}),
         {:ok, records} <- Log.read_stream(stream),
         {:ok, event} <- original_only(records, chapter, id),
         :ok <- Envelope.verify(event),
         :ok <- matches_current_row(event.payload, row),
         {:ok, digest} <- Envelope.event_hash(event) do
      {:ok,
       %{
         "obligation_id" => id,
         "revision" => event.stream_seq,
         "source_event_hash" => digest,
         "debtor_id" => row.debtor_id,
         "creditor_id" => row.creditor_id,
         "amount_minor" => row.amount_minor,
         "denomination" => row.denomination
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_source_history, id}}
    end
  end

  defp original_only(
         [%Envelope{type: "ObligationRecorded", chapter_id: chapter, payload: payload} = event],
         chapter,
         id
       ) do
    if payload["obligation_id"] == id and event.stream_seq == 1 do
      {:ok, event}
    else
      {:error, {:invalid_source_history, id}}
    end
  end

  defp original_only(_, _chapter, id), do: {:error, {:unsupported_source_history, id}}

  defp matches_current_row(payload, row) do
    cited = %{
      "debtor_id" => row.debtor_id,
      "creditor_id" => row.creditor_id,
      "amount_minor" => row.amount_minor,
      "denomination" => row.denomination
    }

    if Map.take(payload, Map.keys(cited)) == cited do
      :ok
    else
      {:error, :source_revised_or_fold_mismatch}
    end
  end
end
