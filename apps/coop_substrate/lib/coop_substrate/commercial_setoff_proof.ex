defmodule CoopSubstrate.CommercialSetoffProof do
  @moduledoc """
  Inert, source-bound bilateral setoff verification contract (V1).

  This is NOT an event type, an append authorization, a legal discharge, or
  financial settlement. In particular, a legacy `NettingExecuted` signature
  authenticates aggregate values but does NOT authenticate this commitment.

  `prepare/8` hashes every current source ID, source revision, source-event
  digest, parties, amount and denomination, as well as the current key and
  independently supplied agency-grant references for both participants.
  `verify/6` checks both distinct Ed25519 consent signatures against the
  same domain-separated canonical bytes. No signing key is held here.

  The caller MUST independently authenticate source-event revisions, grant
  registries, legal evidence and policy decisions. The historic Membership
  obligation fold has neither source revisions nor corporate agency grants;
  caller-supplied snapshots are NOT proof of those facts. Replay checks are
  snapshot checks only, NOT a durable reservation or admission fence.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Crypto

  @domain "biz-kit/commercial-setoff/source-bound/v1\0"
  @max_minor 9_223_372_036_854_775_807
  @source_fields ~w(amount_minor creditor_id debtor_id denomination obligation_id revision source_event_hash)
  @evidence_fields ~w(discharge_evidence_digest jurisdiction legal_basis_digest policy_decision_digest)

  @doc """
  Construct unsigned, non-admissible evidence from a caller-supplied snapshot.

  Sources are string-keyed maps with all `@source_fields`: revision is a
  positive authoritative revision number; source_event_hash is a raw 32-byte
  digest. The required current agency-grant map is keyed by actor ID:
  `%{actor_id => %{key_id: ..., digest: <<_::256>>, active: true}}`.
  Evidence is a string-keyed map with all `@evidence_fields`, whose digests
  are raw bytes. Hash presence never establishes legal efficacy.

  This deliberately does not construct or modify `NettingExecuted`.
  """
  def prepare(gate, chapter, {a, b}, denomination, sources, intent_id, grants, evidence)
      when is_map(gate) do
    with :ok <- check_header(chapter, a, b, denomination, intent_id),
         {:ok, entries, a_to_b, b_to_a} <- normalize_sources(sources, a, b, denomination),
         :ok <- match_current_gate(gate, chapter, a, b, denomination, entries),
         {:ok, authorities} <- current_authorities(gate, chapter, [a, b], grants),
         {:ok, legal} <- legal_refs(evidence) do
      body = %{
        "version" => 1,
        "domain" => "biz-kit/commercial-setoff/source-bound/v1",
        "chapter_id" => chapter,
        "intent_id" => intent_id,
        "party_a" => a,
        "party_b" => b,
        "denomination" => denomination,
        "sources" => entries,
        "a_to_b" => a_to_b,
        "b_to_a" => b_to_a,
        "setoff" => min(a_to_b, b_to_a),
        "authorities" => authorities,
        "legal_evidence" => legal
      }

      with {:ok, encoded} <- Canonical.encode(body) do
        bytes = @domain <> encoded

        {:ok,
         %{
           body: body,
           commitment: :crypto.hash(:sha256, bytes),
           signing_bytes: bytes,
           status: :unsigned_inert_contract,
           signed_event_binding: :none,
           legal_effect: :not_established,
           settlement: :none
         }}
      end
    end
  end

  def prepare(_, _, _, _, _, _, _, _), do: {:error, :invalid_request}

  @doc """
  Verify source snapshot, current member keys, supplied active grants,
  distinct signatures and a caller-owned replay snapshot.

  `spent` may contain commitment bytes or `{chapter_id, intent_id}`.
  A real append gate MUST enforce unique reservation/discharge IDs durably
  under its own serialized transaction, including restarts and races; this
  pure check makes NO admission claim and does not mutate `spent`.
  """
  def verify(proof, gate, current_sources, current_grants, signatures, spent \\ MapSet.new())

  def verify(
        %{body: body, commitment: commitment, signing_bytes: bytes} = proof,
        gate,
        current_sources,
        current_grants,
        signatures,
        %MapSet{} = spent
      )
      when is_map(body) and is_map(gate) and is_binary(commitment) and
             is_binary(bytes) and is_map(signatures) do
    with :ok <- check_spent(body, commitment, spent),
         {:ok, expected} <-
           prepare(
             gate,
             body["chapter_id"],
             {body["party_a"], body["party_b"]},
             body["denomination"],
             current_sources,
             body["intent_id"],
             current_grants,
             evidence_input(body["legal_evidence"])
           ),
         :ok <- compare_exact(proof, expected),
         :ok <- verify_consents(expected, signatures) do
      {:ok,
       %{
         status: :inert_cryptographic_checks_only,
         commitment: commitment,
         admission: :not_authorized,
         legally_effective_discharge: :not_verified,
         financial_settlement: :none
       }}
    end
  end

  def verify(_, _, _, _, _, _), do: {:error, :invalid_verification_request}

  defp check_header(chapter, a, b, denomination, intent_id) do
    if Enum.all?([chapter, a, b, denomination, intent_id], &(is_binary(&1) and &1 != "")) and
         a < b do
      :ok
    else
      {:error, :invalid_header}
    end
  end

  defp normalize_sources(sources, a, b, denomination)
       when is_list(sources) and length(sources) >= 2 and length(sources) <= 256 do
    result =
      Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
        case normalize_source(source, a, b, denomination) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, entries} <- result do
      entries = Enum.sort_by(entries, & &1["obligation_id"])
      ids = Enum.map(entries, & &1["obligation_id"])

      totals =
        Enum.reduce(entries, {0, 0}, fn entry, {ab, ba} ->
          if entry["debtor_id"] == a do
            {ab + entry["amount_minor"], ba}
          else
            {ab, ba + entry["amount_minor"]}
          end
        end)

      {ab, ba} = totals

      cond do
        length(Enum.uniq(ids)) != length(ids) -> {:error, :duplicate_source}
        ab == 0 or ba == 0 -> {:error, :not_bilateral}
        ab > @max_minor or ba > @max_minor -> {:error, :total_out_of_range}
        true -> {:ok, entries, ab, ba}
      end
    end
  end

  defp normalize_sources(_, _, _, _), do: {:error, :invalid_sources}

  defp normalize_source(%{} = source, a, b, denomination) do
    id = source["obligation_id"]
    revision = source["revision"]
    hash = source["source_event_hash"]
    debtor = source["debtor_id"]
    creditor = source["creditor_id"]
    amount = source["amount_minor"]

    cond do
      Enum.sort(Map.keys(source)) != @source_fields ->
        {:error, :invalid_source_shape}

      not (is_binary(id) and id != "" and is_integer(revision) and revision > 0 and
              revision <= @max_minor and match?(<<_::256>>, hash)) ->
        {:error, :invalid_source_revision_or_digest}

      not ({debtor, creditor} in [{a, b}, {b, a}]) ->
        {:error, :invalid_source_parties}

      source["denomination"] != denomination ->
        {:error, :cross_currency_source}

      not (is_integer(amount) and amount > 0 and amount <= @max_minor) ->
        {:error, :invalid_source_amount}

      true ->
        {:ok, Map.put(source, "source_event_hash", {:bytes, hash})}
    end
  end

  defp normalize_source(_, _, _, _), do: {:error, :invalid_source_shape}

  defp match_current_gate(%{obligations: obligations}, chapter, a, b, denomination, entries)
       when is_map(obligations) do
    current_ids =
      obligations
      |> Enum.filter(fn
        {{^chapter, _id}, %{open: true, denomination: ^denomination} = ob} ->
          {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}]

        _ ->
          false
      end)
      |> Enum.map(fn {{_chapter, id}, _} -> id end)
      |> Enum.sort()

    source_ids = Enum.map(entries, & &1["obligation_id"])

    if source_ids != current_ids do
      {:error, :source_set_changed}
    else
      Enum.find_value(entries, :ok, fn entry ->
        current = obligations[{chapter, entry["obligation_id"]}]

        cited = %{
          debtor_id: entry["debtor_id"],
          creditor_id: entry["creditor_id"],
          amount_minor: entry["amount_minor"],
          denomination: entry["denomination"]
        }

        unless Map.take(current, Map.keys(cited)) == cited do
          {:error, {:source_changed, entry["obligation_id"]}}
        end
      end)
    end
  end

  defp match_current_gate(_, _, _, _, _, _), do: {:error, :invalid_gate}

  defp current_authorities(%{members: members}, chapter, actors, grants)
       when is_map(members) and is_map(grants) do
    Enum.reduce_while(actors, {:ok, []}, fn actor, {:ok, acc} ->
      member = members[{chapter, actor}]
      grant = grants[actor]

      cond do
        not is_map(member) -> {:halt, {:error, {:member_missing, actor}}}
        not is_map(grant) or grant[:active] != true -> {:halt, {:error, {:authority_inactive, actor}}}
        grant[:key_id] != member[:key_id] -> {:halt, {:error, {:authority_key_stale, actor}}}
        not (is_binary(member[:key_id]) and member[:key_id] != "" and
               match?(<<_::256>>, member[:pubkey]) and match?(<<_::256>>, grant[:digest])) ->
          {:halt, {:error, {:invalid_authority, actor}}}

        true ->
          entry = %{
            "actor_id" => actor,
            "key_id" => member.key_id,
            "pubkey" => {:bytes, member.pubkey},
            "grant_digest" => {:bytes, grant.digest}
          }

          {:cont, {:ok, [entry | acc]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp current_authorities(_, _, _, _), do: {:error, :invalid_authority_registry}

  defp legal_refs(%{} = evidence) do
    if Enum.sort(Map.keys(evidence)) == @evidence_fields and
         is_binary(evidence["jurisdiction"]) and evidence["jurisdiction"] != "" and
         Enum.all?(
           ["legal_basis_digest", "discharge_evidence_digest", "policy_decision_digest"],
           &match?(<<_::256>>, evidence[&1])
         ) do
      {:ok,
       Map.new(evidence, fn
         {"jurisdiction", value} -> {"jurisdiction", value}
         {key, bytes} -> {key, {:bytes, bytes}}
       end)}
    else
      {:error, :unverified_or_missing_legal_refs}
    end
  end

  defp legal_refs(_), do: {:error, :unverified_or_missing_legal_refs}

  defp evidence_input(%{} = evidence) do
    Map.new(evidence, fn
      {"jurisdiction", value} -> {"jurisdiction", value}
      {key, {:bytes, bytes}} -> {key, bytes}
      {key, value} -> {key, value}
    end)
  end

  defp evidence_input(_), do: %{}

  defp check_spent(body, digest, spent) do
    if MapSet.member?(spent, digest) or
         MapSet.member?(spent, {body["chapter_id"], body["intent_id"]}) do
      {:error, :replayed_intent}
    else
      :ok
    end
  end

  defp compare_exact(proof, expected) do
    if proof.body == expected.body and proof.commitment == expected.commitment and
         proof.signing_bytes == expected.signing_bytes do
      :ok
    else
      {:error, :stale_or_substituted_source_binding}
    end
  end

  defp verify_consents(%{body: body, signing_bytes: bytes}, signatures) do
    [a, b] = [body["party_a"], body["party_b"]]

    if Enum.sort(Map.keys(signatures)) != [a, b] do
      {:error, :two_independent_consents_required}
    else
      Enum.find_value(body["authorities"], :ok, fn authority ->
        actor = authority["actor_id"]
        signer = signatures[actor]

        case {authority, signer} do
          {%{"key_id" => key_id, "pubkey" => {:bytes, pubkey}},
           %{key_id: ^key_id, signature: sig}} when is_binary(sig) ->
            unless Crypto.verify(bytes, sig, pubkey), do: {:error, {:invalid_consent, actor}}

          _ ->
            {:error, {:invalid_consent, actor}}
        end
      end)
    end
  end
end
