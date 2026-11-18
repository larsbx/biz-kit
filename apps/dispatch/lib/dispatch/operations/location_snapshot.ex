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
  @response_limit 262_144

  @doc "The maximum complete roster this view serves."
  def limit, do: @limit

  @doc "The complete snapshot wire budget, including JSON escaping."
  def response_limit, do: @response_limit

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
  @spec build(Actor.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def build(actor, opts \\ []) do
    with {:ok, actor} <- authorize(actor) do
      cursor = Keyword.get_lazy(opts, :cursor, &new_cursor/0)
      participants = roster(actor)

      if length(participants) > @limit do
        {:ok, result(actor, "capacity_exceeded", [], [], cursor)}
      else
        ids = Enum.map(participants, & &1.participant_id)
        grants = active_grants(actor, ids)
        watches = watchers(grants)
        positions = positions(actor, grants)

        rows =
          Enum.map(participants, fn participant ->
            participant
            |> Map.put(:ref, %{kind: "participant", id: participant.participant_id})
            |> Map.put(:position, Map.get(positions, participant.participant_id))
          end)

        {:ok, result(actor, "ok", rows, watches, cursor)}
      end
    end
  end

  @doc "Opaque identity of the selected authority; it contains no coordinates."
  @spec scope_key(Actor.t()) :: String.t()
  def scope_key(%Actor{} = actor) do
    digest({
      2,
      actor.tenant_id,
      actor.principal_type,
      actor.principal_id,
      actor.role_assignment.id,
      actor.role_assignment.organization_id
    })
  end

  @doc "A fresh response lifetime. Stream cursors are server-owned, never resumed."
  def new_cursor, do: %{stream_id: Ecto.UUID.generate(), sequence: 0}

  @doc "Fresh, separate authority for reading load and assignment context."
  @spec authorize_work(Actor.t()) :: {:ok, Actor.t()} | {:error, :not_found}
  def authorize_work(actor) do
    with {:ok, actor} <- authorize(actor),
         {:ok, actor} <- authorize_board(actor) do
      {:ok, actor}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Current organization-scoped board reads, independent of location access."
  @spec authorize_board(Actor.t()) :: {:ok, Actor.t()} | {:error, :not_found}
  def authorize_board(%Actor{} = actor) do
    with {:ok, actor} <- PrincipalResolution.authorize(actor, "load.read"),
         {:ok, actor} <- PrincipalResolution.authorize(actor, "assignment.read"),
         true <- Actor.can?(actor, "load.read"),
         true <- actor.role_assignment.scope_type == :ORGANIZATION,
         true <- is_nil(actor.role_assignment.scope_id) do
      {:ok, actor}
    else
      _ -> {:error, :not_found}
    end
  end

  def authorize_board(_), do: {:error, :not_found}

  defp result(actor, status, participants, watches, cursor) do
    scope = %{
      key: scope_key(actor),
      organization: %{kind: "organization", id: actor.role_assignment.organization_id}
    }

    coverage = %{
      population: "active_participants",
      complete: status == "ok",
      returned: length(participants),
      total: if(status == "ok", do: length(participants)),
      limit: @limit,
      next_cursor: nil
    }

    work_access = match?({:ok, _}, authorize_board(actor))

    result = %{
      actor: actor,
      watch_ids: watches,
      snapshot: %{
        schema_version: 2,
        status: status,
        generated_at: DateTime.to_iso8601(actor.at),
        limit: @limit,
        scope: scope,
        query: %{area: "organization", time: "latest"},
        coordinates: %{crs: "EPSG:4326", units: "degrees", order: "named_lat_lng"},
        source: %{
          kind: "dispatch_location_projection",
          # Content identity only: these revalidated set reads do not establish
          # a transaction-wide database snapshot or commit watermark.
          revision: digest({scope, status, coverage, work_access, participants})
        },
        cursor: cursor,
        coverage: coverage,
        work_access: work_access,
        participants: participants
      }
    }

    if status == "ok" and
         IO.iodata_length(Jason.encode_to_iodata!(result.snapshot)) > @response_limit do
      # Count alone does not bound arbitrary stored labels. Never publish a
      # truncated roster or retain device watches for an unusable snapshot.
      result(actor, "capacity_exceeded", [], [], cursor)
    else
      result
    end
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
        observation_id: type(s.id, :binary_id),
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
    |> Enum.filter(&valid_position?/1)
    |> Map.new(fn sample ->
      position =
        sample
        |> Map.delete(:participant_id)
        |> Map.delete(:observation_id)
        |> Map.put(:observation_ref, %{kind: "location_observation", id: sample.observation_id})
        |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
        |> Map.update!(:received_at, &DateTime.to_iso8601/1)

      {sample.participant_id, position}
    end)
  end

  defp valid_position?(sample) do
    is_number(sample.lat) and sample.lat >= -90 and sample.lat <= 90 and
      is_number(sample.lng) and sample.lng >= -180 and sample.lng <= 180 and
      is_number(sample.accuracy_m) and sample.accuracy_m >= 0
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)
end
