defmodule ResearchCore.Access do
  @moduledoc """
  Pure, inert oral-history release-eligibility kernel for FieldWitness.

  This does NOT authenticate a narrator, verify signatures, store media, admit
  a ledger event, or authorize a person to download an artifact. The eventual
  host must authenticate the actor and check their current record-specific
  authority before calling review/7. It must supply authoritative, replayed
  state, not a client-submitted snapshot.

  Consent and community approval are independent and exact to a record,
  material kind and audience. A sponsor has no reviewer role. Revocation
  removes future release eligibility; it cannot recall existing exports.
  """

  @materials [:audio, :transcript, :excerpt]
  @audiences [:research, :public]
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/

  @type scope :: {String.t(), String.t(), String.t()}
  @type actor :: {:narrator, String.t()} | {:community, String.t()}

  @doc """
  Create a record-specific candidate for one project and one community.

  Narrator identifiers are sorted for deterministic replay. The caller must
  establish narrator membership and community authority independently.
  No recordings, signatures, personal data or content digests are retained.
  """
  @spec new_record(scope(), String.t(), [String.t()], String.t()) ::
          {:ok, map()} | {:error, :invalid_record}
  def new_record({chapter, tenant, project} = scope, record_id, narrators, community_id) do
    ids = [chapter, tenant, project, record_id, community_id]

    if Enum.all?(ids, &valid_id?/1) and is_list(narrators) and
         length(narrators) in 1..32 and Enum.all?(narrators, &valid_id?/1) and
         length(Enum.uniq(narrators)) == length(narrators) do
      {:ok,
       %{
         scope: scope,
         record_id: record_id,
         narrator_ids: Enum.sort(narrators),
         community_id: community_id,
         grants: MapSet.new(),
         revision: 0
       }}
    else
      {:error, :invalid_record}
    end
  end

  def new_record(_, _, _, _), do: {:error, :invalid_record}

  @doc """
  Apply one host-authenticated, revision-fenced, record-scoped review.

  A review grants or revokes a material/audience pair. It is not a signature
  verification API. Host acceptance must additionally bind signer identity,
  source revision and event identity in the common signed ledger.
  """
  @spec review(map(), scope(), actor(), atom(), atom(), atom(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom()}
  def review(
        %{scope: record_scope, revision: revision, grants: grants} = record,
        scope,
        actor,
        action,
        material,
        audience,
        expected_revision
      ) do
    cond do
      scope != record_scope ->
        {:error, :record_scope_mismatch}

      revision != expected_revision ->
        {:error, :stale_record_revision}

      not valid_actor?(record, actor) ->
        {:error, :unauthorized_record_reviewer}

      action not in [:grant, :revoke] or material not in @materials or
          audience not in @audiences ->
        {:error, :invalid_review}

      true ->
        key = {actor, material, audience}
        granted? = MapSet.member?(grants, key)

        case {action, granted?} do
          {:grant, false} ->
            {:ok, %{record | revision: revision + 1, grants: MapSet.put(grants, key)}}

          {:revoke, true} ->
            {:ok, %{record | revision: revision + 1, grants: MapSet.delete(grants, key)}}

          _ ->
            {:error, :unchanged_record_review}
        end
    end
  end

  def review(_, _, _, _, _, _, _), do: {:error, :invalid_record}

  @doc """
  Whether a specific material can be released to an audience in principle.

  All named narrators AND the named community must have active grants for
  the exact material and audience. A true result does NOT authorize a person:
  the host must separately check their current access grant and artifact
  availability, privacy rules, ethical approval and publication policies.
  """
  @spec release_eligible?(map(), scope(), atom(), atom()) :: boolean()
  def release_eligible?(
        %{scope: record_scope, community_id: community, narrator_ids: narrators, grants: grants},
        scope,
        material,
        audience
      )
      when material in @materials and audience in @audiences do
    scope == record_scope and
      MapSet.member?(grants, {{:community, community}, material, audience}) and
      Enum.all?(narrators, fn narrator ->
        MapSet.member?(grants, {{:narrator, narrator}, material, audience})
      end)
  end

  def release_eligible?(_, _, _, _), do: false

  defp valid_actor?(%{community_id: community}, {:community, id}), do: id == community
  defp valid_actor?(%{narrator_ids: narrators}, {:narrator, id}), do: id in narrators
  defp valid_actor?(_, _), do: false

  defp valid_id?(id) when is_binary(id) do
    byte_size(id) <= 128 and Regex.match?(@id, id)
  end

  defp valid_id?(_), do: false
end
