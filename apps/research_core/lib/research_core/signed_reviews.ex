defmodule ResearchCore.SignedReviews do
  @moduledoc """
  Pure Ed25519 verification and record-specific consent review preflight.

  The signing format uses an explicit domain separator, length-delimited
  strings and fixed-width revision/epoch integers. Signature verification
  does not establish narrator identity or community representation:
  the host MUST resolve `authority` from its current signed, revocable
  authority store, never from a sponsor or a user-supplied snapshot.

  An accepted preview is NOT a ledger event or download authorization.
  """

  alias ResearchCore.Access

  @domain "FieldWitness/ReviewIntent/v1" <> <<0>>
  @identity ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @limit 9_223_372_036_854_775_807
  @fields ~w(scope record_id actor action material audience expected_revision key_id key_epoch)a

  @doc """
  Exact bytes signed by a narrator's or community representative's current key.

  The intent has precisely nine fields; no unsigned extension fields are
  accepted. The domain and every field, including scope, record, material,
  audience, actor, key id, epoch and expected revision, are bound.
  """
  def signing_bytes(%{} = intent) do
    with :ok <- shape(intent),
         {:ok, {role, actor_id}} <- actor_parts(intent.actor) do
      {chapter, tenant, project} = intent.scope

      fields = [
        chapter,
        tenant,
        project,
        intent.record_id,
        role,
        actor_id,
        Atom.to_string(intent.action),
        Atom.to_string(intent.material),
        Atom.to_string(intent.audience),
        intent.key_id
      ]

      {:ok,
       IO.iodata_to_binary([
         @domain,
         Enum.map(fields, fn value ->
           <<byte_size(value)::unsigned-big-32, value::binary>>
         end),
         <<intent.expected_revision::unsigned-big-64, intent.key_epoch::unsigned-big-64>>
       ])}
    end
  end

  def signing_bytes(_), do: {:error, :invalid_review_intent}

  @doc """
  Verify a signature against *currently trusted* authority and apply the
  existing revision-fenced review rule.

  The caller must obtain `authority` from the authoritative signed grant
  projection, enforce current key epoch/revocation and atomically append the
  eventual event through CoopSubstrate. There is no such host in this slice.
  """
  def verify_and_apply(record, intent, signature, authority) do
    with {:ok, bytes} <- signing_bytes(intent),
         :ok <- exact_record(record, intent),
         :ok <- current_authority(authority, intent),
         :ok <- verify_signature(bytes, signature, authority.public_key) do
      Access.review(
        record,
        intent.scope,
        intent.actor,
        intent.action,
        intent.material,
        intent.audience,
        intent.expected_revision
      )
    end
  end

  defp shape(i) do
    valid_scope =
      case Map.get(i, :scope) do
        {chapter, tenant, project} ->
          Enum.all?([chapter, tenant, project], &id?/1)

        _ ->
          false
      end

    if Enum.sort(Map.keys(i)) == Enum.sort(@fields) and
         valid_scope and id?(i.record_id) and id?(i.key_id) and
         i.action in [:grant, :revoke] and
         i.material in [:audio, :transcript, :excerpt] and
         i.audience in [:research, :public] and
         whole?(i.expected_revision) and whole?(i.key_epoch) do
      :ok
    else
      {:error, :invalid_review_intent}
    end
  end

  defp actor_parts({role, id}) when role in [:narrator, :community] do
    if id?(id), do: {:ok, {Atom.to_string(role), id}}, else: {:error, :invalid_review_intent}
  end

  defp actor_parts(_), do: {:error, :invalid_review_intent}

  defp id?(value) when is_binary(value),
    do: byte_size(value) <= 128 and Regex.match?(@identity, value)

  defp id?(_), do: false

  defp whole?(n), do: is_integer(n) and n >= 0 and n <= @limit

  defp exact_record(%{scope: scope, record_id: id, revision: revision}, intent) do
    if scope == intent.scope and id == intent.record_id and revision == intent.expected_revision,
      do: :ok,
      else: {:error, :record_or_revision_mismatch}
  end

  defp exact_record(_, _), do: {:error, :record_or_revision_mismatch}

  defp current_authority(
         %{
           active: true,
           scope: scope,
           actor: actor,
           key_id: key_id,
           key_epoch: epoch,
           public_key: pubkey
         },
         intent
       ) do
    if scope == intent.scope and actor == intent.actor and
         key_id == intent.key_id and epoch == intent.key_epoch and
         is_binary(pubkey) and byte_size(pubkey) == 32 do
      :ok
    else
      {:error, :review_authority_not_current}
    end
  end

  defp current_authority(_, _), do: {:error, :review_authority_not_current}

  defp verify_signature(bytes, signature, pubkey)
       when is_binary(signature) and byte_size(signature) == 64 do
    if :crypto.verify(:eddsa, :none, bytes, signature, [pubkey, :ed25519]),
      do: :ok,
      else: {:error, :invalid_review_signature}
  rescue
    _ -> {:error, :invalid_review_signature}
  end

  defp verify_signature(_, _, _), do: {:error, :invalid_review_signature}
end
