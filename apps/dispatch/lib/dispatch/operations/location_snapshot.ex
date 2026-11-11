defmodule Dispatch.Operations.LocationSnapshot do
  @moduledoc """
  A bounded, read-only location projection for the selected carrier.

  Every build revalidates the selected authority, then reads a scoped roster,
  current consent and the latest sample covered by that same consent. The
  three set queries do not rebuild one participant view per row. A roster over
  the limit produces an explicit empty snapshot instead of hiding part of it.
  """

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Access.Actor
  alias Dispatch.Identity.PrincipalResolution

  @limit 200

  @doc "The maximum complete roster this view serves."
  def limit, do: @limit

  @doc "The fresh, explicitly authorized organization role behind a map read."
  @spec authorize(Actor.t()) :: {:ok, Actor.t()} | {:error, :not_found}
  def authorize(%Actor{} = actor) do
    with {:ok, fresh} <- PrincipalResolution.authorize(actor, "operations.participant.read"),
         true <- Actor.can?(fresh, "operations.location.precise.read"),
         true <- fresh.role_assignment.scope_type == :ORGANIZATION,
         true <- is_nil(fresh.role_assignment.scope_id) do
      {:ok, fresh}
    else
      _ -> {:error, :not_found}
    end
  end

  def authorize(_), do: {:error, :not_found}

  @doc "A complete snapshot and the participants whose devices may be watched."
  @spec build(Actor.t()) :: {:ok, map()} | {:error, :not_found}
  def build(actor) do
    with {:ok, actor} <- authorize(actor) do
      participants = roster(actor)

      if length(participants) > @limit do
        {:ok, result(actor, "capacity_exceeded", [], [])}
      else
        ids = Enum.map(participants, & &1.participant_id)
        grants = active_grants(actor, ids)
        watches = watchers(grants)
        positions = positions(actor, grants)

        rows =
          Enum.map(participants, fn participant ->
            Map.put(participant, :position, Map.get(positions, participant.participant_id))
          end)

        {:ok, result(actor, "ok", rows, watches)}
      end
    end
  end

  defp result(actor, status, participants, watches) do
    %{
      actor: actor,
      watch_ids: watches,
      snapshot: %{
        schema_version: 1,
        status: status,
        generated_at: DateTime.to_iso8601(actor.at),
        limit: @limit,
        participants: participants
      }
    }
  end

  defp roster(actor) do
    from(p in "participants",
      where: p.tenant_id == type(^actor.tenant_id, :binary_id),
      where: p.home_organization_id == type(^actor.role_assignment.organization_id, :binary_id),
      where: p.status == "ACTIVE",
      order_by: [asc: p.public_name, asc: p.id],
      limit: ^(@limit + 1),
      select: %{participant_id: type(p.id, :binary_id), public_name: p.public_name}
    )
    # REVIEWED-UNAUTHORIZED: authorize/1 checked the fresh selected organization
    # role. This projection binds both tenant and organization before reading.
    |> Dispatch.Repo.all()
  end

  defp active_grants(actor, ids) do
    from(c in "consent_grants",
      where: c.tenant_id == type(^actor.tenant_id, :binary_id),
      where: c.participant_id in type(^ids, {:array, :binary_id}),
      where: c.kind == "LOCATION_SHARING" and c.granted_at <= type(^actor.at, :utc_datetime_usec),
      where: is_nil(c.expires_at) or c.expires_at > type(^actor.at, :utc_datetime_usec),
      where: is_nil(c.revoked_at) or c.revoked_at > type(^actor.at, :utc_datetime_usec)
    )
  end

  defp watchers(grants) do
    from(c in grants,
      distinct: c.participant_id,
      order_by: c.participant_id,
      select: type(c.participant_id, :binary_id)
    )
    # REVIEWED-UNAUTHORIZED: only current consent for the already scoped roster
    # decides demand. A device can be watched before its first sample arrives.
    |> Dispatch.Repo.all()
  end

  defp positions(actor, grants) do
    from(c in grants,
      join: s in "location_samples",
      on: s.consent_grant_id == c.id and s.participant_id == c.participant_id,
      where: s.tenant_id == type(^actor.tenant_id, :binary_id),
      where:
        fragment("?->>'assignment_id'", c.scope_json) == fragment("?::text", s.assignment_id),
      where: s.occurred_at >= c.granted_at,
      where: is_nil(c.expires_at) or s.occurred_at < c.expires_at,
      where: is_nil(c.revoked_at) or s.occurred_at < c.revoked_at,
      distinct: s.participant_id,
      order_by: [asc: s.participant_id, desc: s.occurred_at, desc: s.received_at, desc: s.id],
      select: %{
        participant_id: type(s.participant_id, :binary_id),
        lat: fragment("ST_Y(?::geometry)", s.position),
        lng: fragment("ST_X(?::geometry)", s.position),
        accuracy_m: s.accuracy_m,
        occurred_at: type(s.occurred_at, :utc_datetime_usec),
        received_at: type(s.received_at, :utc_datetime_usec),
        provider: s.provider,
        is_mock: s.is_mock
      }
    )
    # REVIEWED-UNAUTHORIZED: exact sample consent must be current and cover the
    # sample's assignment and acquisition. A new consent cannot expose a sample
    # whose own grant was revoked. No private device or grant identifiers leave.
    |> Dispatch.Repo.all()
    |> Map.new(fn sample ->
      position =
        sample
        |> Map.delete(:participant_id)
        |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
        |> Map.update!(:received_at, &DateTime.to_iso8601/1)

      {sample.participant_id, position}
    end)
  end
end
