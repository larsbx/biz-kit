defmodule Dispatch.Audit.Changes.ChainHash do
  @moduledoc """
  Links an audit entry to the tenant's previous one (Section 22.3).

  The hash covers the entry's own content *and* the previous hash, so changing
  any earlier row invalidates every row after it. That is what makes the stream
  append-only in a checkable sense rather than by convention.

  Canonicalisation matters more than the algorithm: two runs over the same
  facts must produce the same bytes, so fields are concatenated in a fixed order
  with an explicit separator, and the payload is encoded with sorted keys. A map
  serialised in hash order would produce a different digest on a different BEAM
  and make the chain unverifiable.
  """

  use Ash.Resource.Change

  require Ash.Query

  @separator "\\x1f"

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    tenant = changeset.tenant || Ash.Changeset.get_attribute(changeset, :tenant_id)
    lock_tenant_chain!(tenant)
    previous = previous_hash(changeset)

    changeset
    |> Ash.Changeset.force_change_attribute(:previous_event_hash, previous)
    |> then(fn cs ->
      Ash.Changeset.force_change_attribute(cs, :event_hash, compute_hash(cs, previous))
    end)
  end

  # The lock is transaction-scoped, so every append for one tenant observes the
  # predecessor committed by the append before it. Different tenants retain
  # independent concurrency.
  defp lock_tenant_chain!(tenant) do
    _result =
      Dispatch.Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
        [to_string(tenant)]
      )

    :ok
  end

  defp previous_hash(changeset) do
    tenant = changeset.tenant || Ash.Changeset.get_attribute(changeset, :tenant_id)

    # REVIEWED-UNAUTHORIZED: reads only the immediately preceding entry's hash
    # to link the chain. Subjecting it to the actor's read policy would make the
    # chain depend on who happened to write the entry — an actor who cannot read
    # audit history would silently start a new chain, which is precisely the
    # tampering the chain exists to detect. No field but the hash is used, and
    # nothing is returned to the caller.
    Dispatch.Audit.AuditEvent
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false, tenant: tenant)
    |> case do
      {:ok, [%{event_hash: hash}]} -> hash
      _ -> nil
    end
  end

  defp compute_hash(changeset, previous) do
    [
      previous || "",
      to_string(Ash.Changeset.get_attribute(changeset, :tenant_id)),
      to_string(Ash.Changeset.get_attribute(changeset, :event_type)),
      to_string(Ash.Changeset.get_attribute(changeset, :actor_type)),
      to_string(Ash.Changeset.get_attribute(changeset, :actor_id)),
      to_string(Ash.Changeset.get_attribute(changeset, :role_assignment_id)),
      to_string(Ash.Changeset.get_attribute(changeset, :subject_type)),
      to_string(Ash.Changeset.get_attribute(changeset, :subject_id)),
      occurred_at(changeset),
      canonical_payload(Ash.Changeset.get_attribute(changeset, :payload_json))
    ]
    |> Enum.join(@separator)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp occurred_at(changeset) do
    case Ash.Changeset.get_attribute(changeset, :occurred_at) do
      %DateTime{} = at -> DateTime.to_iso8601(at)
      other -> to_string(other)
    end
  end

  # Sorted keys, recursively: map iteration order is unspecified, so an
  # unsorted encoding would hash differently between runs and break the chain.
  defp canonical_payload(payload) when is_map(payload) do
    payload
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(@separator, fn {key, value} ->
      "#{key}=#{canonical_payload(value)}"
    end)
  end

  defp canonical_payload(payload) when is_list(payload) do
    Enum.map_join(payload, ",", &canonical_payload/1)
  end

  defp canonical_payload(payload), do: to_string(payload)
end
