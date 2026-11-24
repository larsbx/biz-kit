defmodule CoopSubstrate.CrossCurrencySourceSnapshot do
  @moduledoc """
  Read-only, fail-closed source-history input for a cross-currency consent
  *preview* from the canonical local business log.

  Supports exactly two open, reciprocal, different-currency original
  ObligationRecorded events. Derives each full recorded event hash and each
  current member key from the signed source-owning log, never from a
  caller-supplied map or a federation advertisement.

  This does not validate invoice performance, corporate agency, actual
  consent, FX/legal classification or contractual discharge. The log head
  check detects an intervening append, not a later append or a rollback.
  It is NOT a reservation, admission, journal, payment or FX writer.
  """

  alias CoopSubstrate.CommercialSourceLineage
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.{Envelope, TypeRegistry}

  @doc """
  Return independently re-read current source hashes and member keys for
  two reciprocal original obligations in different currencies.

  The caller still must verify the *complete* source amounts, currencies,
  revisions, parties and negotiated rate against its exact consent proposal.
  Neither this snapshot nor a cryptographic signature grants write authority.
  """
  def snapshot(chapter, {first_id, second_id})
      when is_binary(chapter) and byte_size(chapter) in 1..256 and
             is_binary(first_id) and is_binary(second_id) do
    cond do
      not String.valid?(chapter) ->
        {:error, :invalid_request}

      first_id == second_id or first_id == "" or second_id == "" ->
        {:error, :invalid_source_pair}

      true ->
        do_snapshot(chapter, Enum.sort([first_id, second_id]))
    end
  end

  def snapshot(_, _), do: {:error, :invalid_request}

  defp do_snapshot(chapter, ids) do
    head_before = Log.head()
    gate = Log.gate()

    with :ok <- Log.verify_chains(),
         {:ok, rows} <- current_rows(gate, chapter, ids),
         {:ok, sources} <- original_sources(rows, chapter, gate),
         {:ok, members} <- current_members(gate, chapter, rows),
         ^head_before <- Log.head() do
      {:ok,
       %{
         chapter_id: chapter,
         source_hashes: Map.new(sources, fn {id, source} -> {id, source.source_event_hash} end),
         sources: sources,
         members: members,
         member_key_epochs:
           Map.new(members, fn {id, _} -> {id, gate.member_key_epochs[{chapter, id}]} end),
         observed_head: head_before,
         source_status: :authenticated_local_original_business_history,
         agency_status: :unverified,
         document_status: :unverified,
         legal_classification: :undetermined,
         consent: :not_verified,
         admission: :not_authorized,
         source_reservation: :none,
         discharge: :none,
         currency_exchange: :none,
         financial_settlement: :none
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :concurrent_ledger_change}
    end
  end

  defp current_rows(%{obligations: obligations} = gate, chapter, [first, second])
       when is_map(obligations) do
    a = obligations[{chapter, first}]
    b = obligations[{chapter, second}]

    cond do
      not (is_map(a) and is_map(b) and a[:open] == true and b[:open] == true) ->
        {:error, :missing_or_closed_original_source}

      a[:denomination] == b[:denomination] ->
        {:error, :same_currency_use_original_setoff}

      not (a[:debtor_id] == b[:creditor_id] and a[:creditor_id] == b[:debtor_id] and
               a[:debtor_id] != a[:creditor_id]) ->
        {:error, :not_reciprocal_business_sources}

      not (is_binary(a[:denomination]) and is_binary(b[:denomination]) and
             is_integer(a[:amount_minor]) and a[:amount_minor] > 0 and
             is_integer(b[:amount_minor]) and b[:amount_minor] > 0) ->
        {:error, :invalid_source_amount_or_currency}

      Enum.any?([first, second], &reserved?(gate, chapter, &1)) ->
        {:error, :source_already_reserved}

      true ->
        {:ok, [{first, a}, {second, b}]}
    end
  end

  defp current_rows(_, _, _), do: {:error, :invalid_local_gate}

  defp reserved?(gate, chapter, id) do
    Map.has_key?(gate.commercial_admission.reservations, {chapter, id}) or
      case Map.get(gate, :commercial_setoff_admission) do
        %{claims: claims} when is_map(claims) ->
          Map.has_key?(claims, {chapter, id})

        _ ->
          false
      end
  end

  defp original_sources(rows, chapter, gate) do
    Enum.reduce_while(rows, {:ok, %{}}, fn {id, row}, {:ok, acc} ->
      case original_source(chapter, id, row, gate) do
        {:ok, source} -> {:cont, {:ok, Map.put(acc, id, source)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp original_source(chapter, id, row, gate) do
    with true <- CommercialSourceLineage.original_only?(gate, chapter, id),
         %{original_signed_core_digest: expected, source_revision: 1} <-
           gate.commercial_source_lineage[{chapter, id}],
         {:ok, stream} <-
           TypeRegistry.stream_id("ObligationRecorded", chapter, %{"obligation_id" => id}),
         {:ok, [%Envelope{} = event]} <- Log.read_stream(stream),
         true <-
           event.type == "ObligationRecorded" and event.chapter_id == chapter and
             event.stream_seq == 1 and event.payload["obligation_id"] == id,
         :ok <- Envelope.verify(event),
         :ok <- same_original_terms(event.payload, row),
         {:ok, signed_bytes} <- Envelope.signing_bytes(event),
         true <- expected == :crypto.hash(:sha256, signed_bytes),
         {:ok, digest} <- Envelope.event_hash(event) do
      {:ok,
       %{
         source_id: id,
         revision: 1,
         source_event_hash: digest,
         original_signed_core_digest: expected,
         debtor: row.debtor_id,
         creditor: row.creditor_id,
         currency: row.denomination,
         amount_minor: row.amount_minor,
         origin: :signed_original_obligation
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, {:unsupported_or_tampered_source_history, id}}
    end
  end

  defp same_original_terms(payload, row) do
    expected = %{
      "debtor_id" => row.debtor_id,
      "creditor_id" => row.creditor_id,
      "denomination" => row.denomination,
      "amount_minor" => row.amount_minor
    }

    if Map.take(payload, Map.keys(expected)) == expected,
      do: :ok,
      else: {:error, :source_fold_mismatch}
  end

  defp current_members(%{members: members}, chapter, rows) when is_map(members) do
    [{_, a}, {_, b}] = rows
    principals = Enum.sort([a.debtor_id, b.debtor_id])

    with true <- Enum.uniq(principals) == principals,
         {:ok, results} <- collect_members(members, chapter, principals),
         [first, second] <- Map.values(results),
         true <- first.key_id != second.key_id and first.pubkey != second.pubkey do
      {:ok, results}
    else
      _ -> {:error, :missing_or_nonindependent_member_keys}
    end
  end

  defp current_members(_, _, _), do: {:error, :invalid_local_member_registry}

  defp collect_members(members, chapter, principals) do
    Enum.reduce_while(principals, {:ok, %{}}, fn id, {:ok, acc} ->
      case Map.get(members, {chapter, id}) do
        %{key_id: key, pubkey: <<_::256>> = pubkey}
        when is_binary(key) and byte_size(key) in 1..256 ->
          {:cont, {:ok, Map.put(acc, id, %{key_id: key, pubkey: pubkey})}}

        _ ->
          {:halt, {:error, :unregistered_business_principal}}
      end
    end)
  end
end
