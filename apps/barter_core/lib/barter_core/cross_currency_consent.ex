defmodule BarterCore.CrossCurrencyConsent do
  @moduledoc """
  Inert, domain-separated bilateral Ed25519 consent contract for the exact
  cross-currency clearing *preview*, not an accounting or discharge event.

  The two source-event hashes and current business key registry MUST be
  authenticated independently by the source owners. This module checks
  cryptographic agreement over the supplied exact data, not the real-world
  validity of invoices, agency grants, licensing or contractual discharge.

  It cannot create, sign, append, reserve, post, exchange or settle anything.
  In particular, its signatures do not authorize legacy NettingExecuted.
  """

  alias BarterCore
  alias BarterCore.CrossCurrencySetoff

  @schema "bizkit.barter.cross-currency-source-consent.v1"
  @domain "biz-kit/cross-currency-source-consent/v1\0"

  @doc """
  Construct identical bytes for two principals to sign independently.

  Source hashes are a map from the two original source IDs to their 32-byte
  signed-event digests. Members are keyed by the principals' original actor
  IDs, with a key_id and 32-byte Ed25519 pubkey for each.

  Latest source proofs and current membership must be independently obtained
  at verification time. The date is a clock assertion, not a durable fence.
  """
  def prepare(plan, chapter, source_hashes, members, now)
      when is_map(plan) and is_binary(chapter) and is_map(source_hashes) and
             is_map(members) and is_integer(now) and now >= 0 do
    with :ok <- valid_chapter(chapter),
         :ok <- verify_current_plan(plan, now),
         {:ok, sources} <- source_terms(plan, source_hashes),
         {:ok, authorities} <- current_authorities(plan, members) do
      fields =
        [@schema, chapter, plan.intent_id, plan.terms_hash] ++
          Enum.flat_map(sources, fn s ->
            [
              s.source_id,
              Integer.to_string(s.revision),
              Base.encode16(s.source_event_hash, case: :lower)
            ]
          end) ++
          Enum.flat_map(authorities, fn a ->
            [
              a.principal,
              a.key_id,
              Base.encode16(a.pubkey, case: :lower)
            ]
          end)

      bytes = @domain <> BarterCore.digest(fields)

      {:ok,
       %{
         schema: @schema,
         chapter_id: chapter,
         plan: plan,
         sources: sources,
         authorities: authorities,
         signing_bytes: bytes,
         commitment: :crypto.hash(:sha256, bytes),
         status: :unsigned_inert_source_bound_proposal,
         source_authentication: :external_not_verified,
         agency_authority: :external_not_verified,
         admission: :not_authorized,
         contractual_discharge: :not_established,
         currency_exchange: :none,
         financial_settlement: :none
       }}
    end
  end

  def prepare(_, _, _, _, _), do: {:error, :invalid_consent_request}

  @doc """
  Reconstruct the complete signed terms using fresh external input and verify
  two independent Ed25519 signatures over the same exact bytes.

  It does not trust a prior proof's own sources, members, timestamps or
  asserted authorizations as a source of freshness or legal permission.
  """
  def verify(proof, latest_plan, chapter, latest_source_hashes, current_members, signatures, now)
      when is_map(proof) and is_map(signatures) do
    with {:ok, expected} <-
           prepare(latest_plan, chapter, latest_source_hashes, current_members, now),
         :ok <- exact_proof(proof, expected),
         :ok <- verify_signatures(expected, signatures) do
      {:ok,
       %{
         status: :inert_cryptographic_consents_only,
         commitment: expected.commitment,
         admission: :not_authorized,
         source_authentication: :external_not_verified,
         agency_authority: :external_not_verified,
         contractual_discharge: :not_established,
         currency_exchange: :none,
         financial_settlement: :none
       }}
    end
  end

  def verify(_, _, _, _, _, _, _), do: {:error, :invalid_verification_request}

  defp valid_chapter(chapter) do
    if byte_size(chapter) in 1..256 and String.valid?(chapter),
      do: :ok,
      else: {:error, :invalid_chapter}
  end

  defp verify_current_plan(plan, now) do
    case Map.fetch(plan, :observed_at) do
      {:ok, observed_at} when is_integer(observed_at) and observed_at <= now ->
        with {:ok, ^plan} <- CrossCurrencySetoff.verify_plan(plan, observed_at),
             true <- plan.a_to_b.valid_until > now and plan.b_to_a.valid_until > now,
             true <- plan.rate.valid_until > now do
          :ok
        else
          {:error, _} -> {:error, :invalid_or_substituted_plan}
          false -> {:error, :expired_source_or_rate}
        end

      _ ->
        {:error, :invalid_observation_time}
    end
  end

  defp source_terms(%{a_to_b: a, b_to_a: b}, source_hashes) do
    sources = [a, b] |> Enum.sort_by(& &1.id)
    ids = Enum.map(sources, & &1.id)

    if ids == Enum.sort(Map.keys(source_hashes)) and
         Enum.all?(ids, &match?(<<_::256>>, Map.get(source_hashes, &1))) do
      {:ok,
       Enum.map(sources, fn source ->
         %{
           source_id: source.id,
           revision: source.revision,
           source_event_hash: Map.fetch!(source_hashes, source.id)
         }
       end)}
    else
      {:error, :missing_or_invalid_source_hashes}
    end
  end

  defp current_authorities(%{a_to_b: a, b_to_a: b}, members) do
    principals = Enum.sort([a.debtor, b.debtor])

    with true <- principals == Enum.sort(Map.keys(members)),
         {:ok, authorities} <- collect_authorities(principals, members),
         true <- independent_authorities?(authorities) do
      {:ok, authorities}
    else
      false -> {:error, :missing_or_nonindependent_business_keys}
      {:error, _} = error -> error
    end
  end

  defp collect_authorities(principals, members) do
    Enum.reduce_while(principals, {:ok, []}, fn principal, {:ok, acc} ->
      case Map.fetch(members, principal) do
        {:ok, %{key_id: key_id, pubkey: pubkey} = member}
        when is_binary(key_id) and byte_size(key_id) in 1..256 and
               is_binary(pubkey) and byte_size(pubkey) == 32 ->
          if Enum.sort(Map.keys(member)) == [:key_id, :pubkey] do
            {:cont, {:ok, [%{principal: principal, key_id: key_id, pubkey: pubkey} | acc]}}
          else
            {:halt, {:error, :invalid_business_key_record}}
          end

        _ ->
          {:halt, {:error, :invalid_business_key_record}}
      end
    end)
    |> case do
      {:ok, reverse} -> {:ok, Enum.reverse(reverse)}
      error -> error
    end
  end

  defp independent_authorities?([a, b]) do
    a.principal != b.principal and
      a.key_id != b.key_id and
      a.pubkey != b.pubkey
  end

  defp independent_authorities?(_), do: false

  defp exact_proof(proof, expected) do
    if proof === expected,
      do: :ok,
      else: {:error, :stale_or_substituted_consent_terms}
  end

  defp verify_signatures(%{authorities: authorities, signing_bytes: bytes}, signatures) do
    principals = Enum.map(authorities, & &1.principal)

    if Enum.sort(Map.keys(signatures)) != principals do
      {:error, :two_independent_consents_required}
    else
      Enum.find_value(authorities, :ok, fn actor ->
        case Map.fetch(signatures, actor.principal) do
          {:ok, %{key_id: key_id, signature: signature} = signed}
          when key_id == actor.key_id and is_binary(signature) and
                 byte_size(signature) == 64 ->
            if Enum.sort(Map.keys(signed)) == [:key_id, :signature] and
                 :crypto.verify(:eddsa, :none, bytes, signature, [actor.pubkey, :ed25519]) do
              false
            else
              {:error, {:invalid_consent, actor.principal}}
            end

          _ ->
            {:error, {:invalid_consent, actor.principal}}
        end
      end)
    end
  end
end
