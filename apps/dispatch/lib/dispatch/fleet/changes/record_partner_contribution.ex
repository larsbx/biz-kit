defmodule Dispatch.Fleet.Changes.RecordPartnerContribution do
  @moduledoc "Bind contributions to server identity, a current stop version, and an audit append."
  use Ash.Resource.Change
  require Ash.Query
  alias Dispatch.Access.Checks.PartnerScope
  alias Dispatch.Fleet.{Stop, ReferenceCipher}
  alias Dispatch.Operations.StopReadinessEvent

  @impl true
  def change(changeset, opts, %{actor: actor}) do
    kind = Keyword.fetch!(opts, :kind)

    changeset
    |> Ash.Changeset.before_action(fn cs -> prepare(cs, actor, kind) end)
    |> Ash.Changeset.after_action(fn cs, record ->
      audit!(cs, record, actor, kind)
      {:ok, record}
    end)
  end

  defp prepare(cs, actor, kind) do
    with {:ok, actor} <- PartnerScope.fresh(actor),
         # A row lock serializes both the basis check and competing readiness
         # submissions. Every writer of confirmed stop data takes the same
         # PostgreSQL row lock, including an ordinary UPDATE.
         {:ok, _} <- lock(actor, Ash.Changeset.get_attribute(cs, :stop_id)),
         :ok <- lock_authority(actor, Ash.Changeset.get_attribute(cs, :stop_id)),
         {:ok, actor} <- PartnerScope.fresh(actor),
         true <-
           Dispatch.Access.Checks.PartnerMutation.match?(actor, %{changeset: cs}, kind: kind),
         {:ok, %Stop{} = stop} <- fetch_stop(cs, actor) do
      cs =
        cs
        |> Ash.Changeset.force_change_attributes(%{
          tenant_id: actor.tenant_id,
          organization_id: actor.role_assignment.organization_id,
          participant_id: actor.principal_id,
          role_assignment_id: actor.role_assignment.id,
          source: :PARTICIPANT,
          recorded_at: actor.at,
          occurred_at: Ash.Changeset.get_attribute(cs, :occurred_at) || actor.at,
          basis_version: stop.version
        })

      if stop.version == Ash.Changeset.get_argument(cs, :expected_version) do
        validate_kind(cs, actor, stop, kind)
      else
        error(cs, :expected_version, "STALE_VERSION: review the current stop before submitting")
      end
    else
      _ -> error(cs, :stop_id, "not available")
    end
  end

  defp lock(actor, stop_id) do
    Dispatch.Repo.query(
      "SELECT id FROM stops WHERE id = $1::uuid AND tenant_id = $2::uuid FOR UPDATE",
      [Ecto.UUID.dump!(stop_id), Ecto.UUID.dump!(actor.tenant_id)]
    )
  end

  # Revocation/end actions UPDATE these rows. Their locks therefore serialize
  # with submission admission, even if a form and its Actor were held offline.
  # REVIEWED-UNAUTHORIZED: locks on authority rows are authorization primitives;
  # no domain data is returned or changed through this SQL.
  defp lock_authority(actor, stop_id) do
    id = Ecto.UUID.dump!(actor.role_assignment.id)
    tenant = Ecto.UUID.dump!(actor.tenant_id)
    org = Ecto.UUID.dump!(actor.role_assignment.organization_id)

    Dispatch.Repo.query!(
      "SELECT id FROM role_assignments WHERE id=$1 AND tenant_id=$2 FOR SHARE",
      [id, tenant]
    )

    Dispatch.Repo.query!(
      "SELECT id FROM stop_parties WHERE stop_id=$1 AND tenant_id=$2 AND organization_id=$3 FOR SHARE",
      [Ecto.UUID.dump!(stop_id), tenant, org]
    )

    if actor.role_assignment.scope_type == :LOAD do
      Dispatch.Repo.query!(
        "SELECT id FROM load_parties WHERE load_id=$1 AND tenant_id=$2 AND organization_id=$3 FOR SHARE",
        [Ecto.UUID.dump!(actor.role_assignment.scope_id), tenant, org]
      )
    end

    :ok
  end

  defp fetch_stop(cs, actor) do
    id = Ash.Changeset.get_attribute(cs, :stop_id)

    Stop
    |> Ash.Query.for_read(:partner)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
  end

  defp validate_kind(cs, actor, stop, :readiness) do
    latest =
      StopReadinessEvent
      |> Ash.Query.filter(stop_id == ^stop.id)
      |> Ash.Query.sort(recorded_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor, tenant: actor.tenant_id)

    latest_id = if latest, do: latest.id

    cond do
      latest_id != Ash.Changeset.get_argument(cs, :expected_latest_id) ->
        error(cs, :expected_latest_id, "STALE_VERSION: readiness changed; review it first")

      DateTime.compare(Ash.Changeset.get_attribute(cs, :occurred_at), DateTime.add(actor.at, 60)) ==
          :gt ->
        error(cs, :occurred_at, "must not be in the future")

      true ->
        cs
    end
  end

  defp validate_kind(cs, _actor, stop, :document) do
    category = Ash.Changeset.get_attribute(cs, :category)
    reference = Ash.Changeset.get_argument(cs, :reference)

    valid_category =
      {stop.kind, category} in [{:PICKUP, :PICKUP_DOCUMENT}, {:DELIVERY, :PROOF_OF_DELIVERY}]

    cond do
      not valid_category ->
        error(cs, :category, "not permitted for this stop")

      not is_binary(reference) or
          not Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.\/ -]{0,499}$/, reference) ->
        error(cs, :reference, "use an opaque document reference, not a URL or content")

      true ->
        case ReferenceCipher.encrypt(reference) do
          {:ok, cipher} ->
            Ash.Changeset.force_change_attribute(cs, :object_reference_ciphertext, cipher)

          _ ->
            error(cs, :reference, "reference storage unavailable")
        end
    end
  end

  defp validate_kind(cs, actor, stop, :proposal) do
    kind = Ash.Changeset.get_attribute(cs, :kind)
    start = Ash.Changeset.get_attribute(cs, :window_start)
    finish = Ash.Changeset.get_attribute(cs, :window_end)
    text = Ash.Changeset.get_attribute(cs, :instructions)
    expires = Ash.Changeset.get_attribute(cs, :expires_at)

    cond do
      is_nil(expires) or DateTime.compare(expires, actor.at) != :gt or
          DateTime.compare(expires, DateTime.add(actor.at, 86400)) == :gt ->
        error(cs, :expires_at, "must be in the next 24 hours")

      kind == :APPOINTMENT and (is_nil(start) or is_nil(finish) or not is_nil(text)) ->
        error(cs, :window_start, "a window proposal requires only a start and end")

      kind == :APPOINTMENT and DateTime.compare(start, finish) != :lt ->
        error(cs, :window_end, "must follow the start")

      kind == :INSTRUCTION and (is_nil(text) or not is_nil(start) or not is_nil(finish)) ->
        error(cs, :instructions, "an instruction proposal requires only instructions")

      true ->
        # Fixed key order and versioned payload. Identity/scope/basis and expiry
        # are hashed with the requested effect. Approval and execution are
        # deliberately absent: Slice 5 must supply their common controls.
        payload =
          Jason.encode!(%Jason.OrderedObject{
            values: [
              {"version", 1},
              {"tenant_id", actor.tenant_id},
              {"stop_id", stop.id},
              {"basis_version", stop.version},
              {"role_assignment_id", actor.role_assignment.id},
              {"kind", to_string(kind)},
              {"window_start", iso(start)},
              {"window_end", iso(finish)},
              {"instructions", text},
              {"expires_at", iso(expires)}
            ]
          })

        cs
        |> Ash.Changeset.force_change_attributes(%{
          canonical_payload: payload,
          payload_sha256: Base.encode16(:crypto.hash(:sha256, payload), case: :lower),
          state: :PROPOSED
        })
    end
  end

  defp iso(nil), do: nil
  defp iso(time), do: DateTime.to_iso8601(time)
  defp error(cs, field, message), do: Ash.Changeset.add_error(cs, field: field, message: message)

  defp audit!(_cs, record, actor, kind) do
    # REVIEWED-UNAUTHORIZED: only the audit append of this authorized Ash action.
    # The append runs in its transaction; an audit failure rolls back the write.
    Dispatch.Audit.AuditEvent
    |> Ash.Changeset.for_create(:record, %{
      tenant_id: actor.tenant_id,
      event_type: "partner.#{kind}.submitted",
      actor_type: actor.principal_type,
      actor_id: actor.principal_id,
      role_assignment_id: actor.role_assignment.id,
      subject_type: "stop",
      subject_id: record.stop_id,
      occurred_at: record.recorded_at,
      correlation_id: record.correlation_id,
      payload_json: %{
        "record_id" => record.id,
        "source" => "PARTICIPANT",
        "basis_version" => record.basis_version
      }
    })
    |> Ash.create!(authorize?: false, tenant: actor.tenant_id)
  end
end
