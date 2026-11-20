defmodule CoopSubstrate.CrossCurrencyAuthorityEvidence do
  @moduledoc """
  Read-only evidence contract for reviewing bilateral cross-currency setoff.

  The host pins the operator and provider. The provider independently
  authenticates business registrations, agents and their current keys, grant
  provenance and revocation, jurisdiction coverage and assessment issuers. It
  resolves fresh evidence for the exact subject and fails on unavailable or
  conflicting authoritative records. Echoing request data does not satisfy
  this behaviour. All timestamps are Unix seconds, with exclusive expiry.

  Success is a point-in-time check of the evidence contract. The result
  carries no admission, payment, posting or discharge authority.
  """

  alias CoopSubstrate.{CrossCurrencySourceSnapshot, Log}

  @activity :bilateral_cross_currency_contractual_setoff_review

  @type ref_id :: String.t()
  @type jurisdiction :: String.t()
  @type sources :: %{required(ref_id()) => <<_::256>>}
  @type key :: %{key_id: ref_id(), pubkey: <<_::256>>, epoch: pos_integer()}
  @type scope :: %{
          activity: :bilateral_cross_currency_contractual_setoff_review,
          operator_ref: ref_id(),
          chapter_id: ref_id(),
          sources: sources()
        }
  @type registration :: %{jurisdiction: jurisdiction(), registry_ref: ref_id(), number: ref_id()}
  @type party_evidence :: %{
          principal: %{registration: registration(), evidence_ref: ref_id()},
          agent: %{id: ref_id(), key: key(), status: :active | :revoked, evidence_ref: ref_id()},
          grant: %{
            scope: scope(),
            principal_id: ref_id(),
            agent_id: ref_id(),
            agent_key: key(),
            member_key: key(),
            id: ref_id(),
            revision: pos_integer(),
            issuer_ref: ref_id(),
            status: :active | :revoked,
            valid_from: non_neg_integer(),
            valid_until: pos_integer()
          }
        }
  @type regulatory_subject :: %{
          scope: scope(),
          principals: %{required(ref_id()) => registration()}
        }
  @type coverage :: %{
          subject: regulatory_subject(),
          governing_law_by_source: %{required(ref_id()) => jurisdiction()},
          operator_jurisdictions: [jurisdiction(), ...],
          activity_jurisdictions: [jurisdiction(), ...],
          evidence_ref: ref_id(),
          valid_from: non_neg_integer(),
          valid_until: pos_integer()
        }
  @type assessment :: %{
          subject: regulatory_subject(),
          jurisdiction: jurisdiction(),
          jurisdiction_evidence_ref: ref_id(),
          decision: :non_prohibited | :prohibited | :undetermined,
          issuer_ref: ref_id(),
          evidence_ref: ref_id(),
          valid_from: non_neg_integer(),
          valid_until: pos_integer()
        }

  @callback resolve_authority(scope(), non_neg_integer()) ::
              {:ok, %{required(ref_id()) => party_evidence()}} | {:error, term()}
  @callback resolve_regulatory(regulatory_subject(), non_neg_integer()) ::
              {:ok,
               %{
                 jurisdictions: coverage(),
                 assessments: %{required(jurisdiction()) => assessment()}
               }}
              | {:error, term()}

  @doc """
  Review the candidate's exact full-record source hashes. The operator and
  provider are in-process host dependencies and must never come from a client.
  """
  def review(chapter, hashes, operator_ref, provider)
      when is_map(hashes) and map_size(hashes) == 2 and is_atom(provider) do
    [first, second] = Map.keys(hashes)

    with true <- reference?(operator_ref) and valid_hashes?(hashes),
         {:ok, snapshot} <- CrossCurrencySourceSnapshot.snapshot(chapter, {first, second}),
         :ok <- match_sources(hashes, snapshot),
         scope = %{
           activity: @activity,
           operator_ref: operator_ref,
           chapter_id: chapter,
           sources: hashes
         },
         {:ok, parties} <- authority(provider, scope, snapshot) do
      registrations = Map.new(parties, fn {id, party} -> {id, party.principal.registration} end)
      subject = %{scope: scope, principals: registrations}
      regulatory = provider.resolve_regulatory(subject, System.system_time(:second))
      checked_at = System.system_time(:second)
      {result, evidence_refs} = regulatory_result(regulatory, subject, checked_at)

      cond do
        Log.head() != snapshot.observed_head ->
          {:error, :concurrent_ledger_change}

        not Enum.all?(parties, fn {_id, party} -> current?(party.grant, checked_at) end) ->
          {:error, :stale_authority_grant}

        true ->
          {:ok,
           %{
             evidence_contract: :verified,
             scope: scope,
             parties: parties,
             checked_at: checked_at,
             observed_head: snapshot.observed_head,
             regulatory_result: result,
             regulatory_evidence_refs: evidence_refs,
             admission: :not_authorized
           }}
      end
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def review(_, _, _, _), do: {:error, :invalid_request}

  defp valid_hashes?(hashes) do
    Enum.all?(hashes, fn {id, hash} -> reference?(id) and match?(<<_::256>>, hash) end)
  end

  defp match_sources(hashes, %{source_hashes: hashes}), do: :ok
  defp match_sources(_, _), do: {:error, :stale_or_substituted_sources}

  defp authority(provider, scope, snapshot) do
    evidence = provider.resolve_authority(scope, System.system_time(:second))
    now = System.system_time(:second)

    case evidence do
      {:ok, parties} when is_map(parties) and map_size(parties) == 2 ->
        with :ok <- validate_parties(parties, scope, snapshot, now),
             [a, b] = Map.values(parties),
             true <- independent?(a, b) do
          {:ok, parties}
        else
          false -> {:error, :nonindependent_business_parties}
          {:error, _} = error -> error
        end

      _ ->
        {:error, :authority_evidence_unavailable}
    end
  end

  defp validate_parties(parties, scope, snapshot, now) do
    Enum.reduce_while(snapshot.members, :ok, fn {id, member}, :ok ->
      key = Map.put(member, :epoch, snapshot.member_key_epochs[id])

      case validate_party(Map.get(parties, id), scope, id, key, now) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_party(
         %{principal: principal, agent: %{id: agent_id, key: agent_key} = agent, grant: grant},
         scope,
         id,
         member_key,
         now
       ) do
    cond do
      match?(%{status: :revoked}, agent) or match?(%{status: :revoked}, grant) ->
        {:error, :revoked_authority}

      not (valid_principal?(principal) and reference?(agent_id) and
             reference?(Map.get(agent, :evidence_ref)) and valid_key?(agent_key) and
             Map.get(agent, :status) == :active and valid_grant?(grant)) ->
        {:error, :invalid_authority_evidence}

      not current?(grant, now) ->
        {:error, :stale_authority_grant}

      not (valid_key?(member_key) and grant.member_key == member_key) ->
        {:error, :stale_member_key_epoch}

      not (grant.scope == scope and grant.principal_id == id and
             grant.agent_id == agent_id and grant.agent_key == agent_key) ->
        {:error, :authority_scope_mismatch}

      true ->
        :ok
    end
  end

  defp validate_party(_, _, _, _, _), do: {:error, :invalid_authority_evidence}

  defp independent?(a, b) do
    a.principal.registration != b.principal.registration and a.agent.id != b.agent.id and
      a.agent.key.pubkey != b.agent.key.pubkey
  end

  defp valid_principal?(%{registration: registration, evidence_ref: ref}) do
    case registration do
      %{jurisdiction: code, registry_ref: registry, number: number} ->
        map_size(registration) == 3 and reference?(code) and reference?(registry) and
          reference?(number) and reference?(ref)

      _ ->
        false
    end
  end

  defp valid_principal?(_), do: false

  defp valid_key?(%{key_id: id, pubkey: <<_::256>>, epoch: epoch} = key),
    do: map_size(key) == 3 and reference?(id) and is_integer(epoch) and epoch > 0

  defp valid_key?(_), do: false

  defp valid_grant?(%{
         id: id,
         revision: revision,
         issuer_ref: issuer,
         status: :active,
         scope: _,
         principal_id: _,
         agent_id: _,
         agent_key: _,
         member_key: _
       }),
       do: reference?(id) and reference?(issuer) and is_integer(revision) and revision > 0

  defp valid_grant?(_), do: false

  defp regulatory_result(
         {:ok, %{jurisdictions: coverage, assessments: assessments}},
         subject,
         now
       )
       when is_map(assessments) do
    with {:ok, required} <- relevant_jurisdictions(coverage, subject, now) do
      reviewed =
        for jurisdiction <- required, into: %{} do
          {jurisdiction,
           decision(
             Map.get(assessments, jurisdiction),
             subject,
             jurisdiction,
             coverage.evidence_ref,
             now
           )}
        end

      result =
        cond do
          Enum.any?(reviewed, fn {_, {decision, _}} -> decision == :prohibited end) ->
            :prohibited

          Enum.all?(reviewed, fn {_, {decision, _}} -> decision == :non_prohibited end) ->
            :non_prohibited

          true ->
            :undetermined
        end

      refs =
        for {jurisdiction, {_, ref}} <- reviewed, ref != nil, into: %{}, do: {jurisdiction, ref}

      {result, %{jurisdiction_coverage: coverage.evidence_ref, assessments: refs}}
    else
      :error -> {:undetermined, nil}
    end
  end

  defp regulatory_result(_, _, _), do: {:undetermined, nil}

  defp relevant_jurisdictions(
         %{
           subject: subject,
           governing_law_by_source: laws,
           operator_jurisdictions: [_ | _] = operator,
           activity_jurisdictions: [_ | _] = activity,
           evidence_ref: ref
         } = coverage,
         subject,
         now
       )
       when is_map(laws) and is_list(operator) and is_list(activity) do
    formation =
      Enum.map(subject.principals, fn {_id, registration} -> registration.jurisdiction end)

    jurisdictions = formation ++ Map.values(laws) ++ operator ++ activity

    if MapSet.new(Map.keys(laws)) == MapSet.new(Map.keys(subject.scope.sources)) and
         Enum.all?(jurisdictions, &reference?/1) and reference?(ref) and current?(coverage, now) do
      {:ok, MapSet.new(jurisdictions)}
    else
      :error
    end
  end

  defp relevant_jurisdictions(_, _, _), do: :error

  defp decision(
         %{
           subject: subject,
           jurisdiction: jurisdiction,
           jurisdiction_evidence_ref: ref,
           decision: result,
           issuer_ref: issuer,
           evidence_ref: evidence
         } = assessment,
         subject,
         jurisdiction,
         ref,
         now
       )
       when result in [:non_prohibited, :prohibited, :undetermined] do
    if reference?(issuer) and reference?(evidence) and current?(assessment, now),
      do: {result, evidence},
      else: {:undetermined, nil}
  end

  defp decision(_, _, _, _, _), do: {:undetermined, nil}

  defp current?(%{valid_from: from, valid_until: until}, now)
       when is_integer(from) and from >= 0 and is_integer(until),
       do: from <= now and now < until

  defp current?(_, _), do: false

  defp reference?(value),
    do: is_binary(value) and byte_size(value) in 1..512 and String.valid?(value)
end
