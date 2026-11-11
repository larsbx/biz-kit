defmodule Dispatch.Operations.LocationWork do
  @moduledoc """
  Read-only work context for one currently visible location observation.

  The browser supplies the opaque observation identity from its current map
  snapshot in a header. It never selects the assignment or load. The server
  follows that admitted sample's assignment and the board's current carrier
  authority. A participant observation is not a vehicle-position assertion.

  These are bounded, independently revalidated reads. The second visibility
  check detects a changed observation or lost consent while work was loading;
  this is not a transaction-wide snapshot or a lock held through HTTP delivery.
  """

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Operations.{Board, LocationSnapshot}

  @stop_limit 200
  @response_limit 65_536

  @doc "The selected-work wire budget, measured after JSON escaping."
  def response_limit, do: @response_limit

  @spec fetch(Dispatch.Access.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :observation_changed | :capacity_exceeded}
  def fetch(actor, participant_id, observation_id) do
    with {:ok, participant_id} <- Ecto.UUID.cast(participant_id),
         {:ok, observation_id} <- Ecto.UUID.cast(observation_id),
         {:ok, actor} <- LocationSnapshot.authorize_work(actor),
         {:ok, _initial} <- visible(actor, participant_id, observation_id),
         {:ok, binding} <- assignment_binding(actor, participant_id, observation_id),
         {:ok, load} <- Board.load(actor, binding.load_id),
         assignment when not is_nil(assignment) <-
           Enum.find(load.assignments, fn assignment ->
             assignment.id == binding.assignment_id and
               assignment.operator_participant_id == participant_id
           end),
         {:ok, current} <- visible(actor, participant_id, observation_id) do
      work =
        load_view(load)
        |> Map.delete(:assignments)
        |> Map.merge(%{
          schema_version: 1,
          status: "ok",
          scope: current.scope,
          generated_at: current.generated_at,
          participant: ref("participant", participant_id),
          observation_ref: ref("location_observation", observation_id),
          assignment: assignment_view(assignment)
        })

      if work |> Jason.encode_to_iodata!() |> IO.iodata_length() <= @response_limit,
        do: {:ok, work},
        else: {:error, :capacity_exceeded}
    else
      {:error, :observation_changed} -> {:error, :observation_changed}
      _ -> {:error, :not_found}
    end
  end

  @doc "An operator's permitted board record, without negotiated rates or contacts."
  @spec load(Dispatch.Access.Actor.t(), String.t()) ::
          {:ok, Dispatch.Access.Actor.t(), map()} | {:error, :not_found}
  def load(actor, load_id) do
    with {:ok, actor} <- LocationSnapshot.authorize_board(actor),
         {:ok, load} <- Board.load(actor, load_id),
         {:ok, actor} <- LocationSnapshot.authorize_board(actor) do
      {:ok, actor, load_view(load)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp visible(actor, participant_id, observation_id) do
    with {:ok, %{snapshot: %{work_access: true} = snapshot}} <- LocationSnapshot.build(actor),
         %{position: %{observation_ref: %{id: current}}} <-
           Enum.find(snapshot.participants, &(&1.participant_id == participant_id)) do
      if current == observation_id,
        do: {:ok, snapshot},
        else: {:error, :observation_changed}
    else
      _ -> {:error, :not_found}
    end
  end

  defp assignment_binding(actor, participant_id, observation_id) do
    from(s in "location_samples",
      join: a in "assignments",
      on: a.id == s.assignment_id and a.tenant_id == s.tenant_id,
      join: l in "loads",
      on: l.id == a.load_id and l.tenant_id == a.tenant_id,
      where: s.id == type(^observation_id, :binary_id),
      where: s.tenant_id == type(^actor.tenant_id, :binary_id),
      where: s.participant_id == type(^participant_id, :binary_id),
      where: a.operator_participant_id == type(^participant_id, :binary_id),
      where:
        l.carrier_organization_id == type(^actor.role_assignment.organization_id, :binary_id),
      select: %{assignment_id: type(a.id, :binary_id), load_id: type(l.id, :binary_id)}
    )
    # REVIEWED-UNAUTHORIZED: exact current observation visibility and fresh map,
    # load and assignment capabilities were checked above. This relation binds
    # tenant, participant and carrier before Board.load rechecks the load scope.
    |> Dispatch.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      binding -> {:ok, binding}
    end
  end

  defp load_view(load) do
    stops = Enum.sort_by(load.stops, &{&1.sequence, &1.id})

    %{
      load: %{
        ref: ref("load", load.id),
        external_reference: load.external_reference,
        commodity_text: load.commodity_text,
        status: Atom.to_string(load.status),
        version: load.version,
        record_href: "/operations/loads/#{load.id}"
      },
      assignments: Enum.map(load.assignments, &assignment_view/1),
      stops: stops |> Enum.take(@stop_limit) |> Enum.map(&stop_view/1),
      stop_coverage: %{
        complete: length(stops) <= @stop_limit,
        returned: min(length(stops), @stop_limit),
        total: length(stops),
        limit: @stop_limit
      },
      next_stop: %{status: "unknown", reason: "stop_progress_not_recorded"}
    }
  end

  defp assignment_view(assignment) do
    %{
      ref: ref("assignment", assignment.id),
      status: Atom.to_string(assignment.status),
      version: assignment.version,
      starts_at: iso(assignment.starts_at),
      ends_at: iso(assignment.ends_at),
      vehicle_ref: ref("vehicle", assignment.vehicle_id),
      trailer_ref: ref("trailer", assignment.trailer_id)
    }
  end

  defp stop_view(stop) do
    position = stop_position(stop.position)

    %{
      ref: ref("stop", stop.id),
      sequence: stop.sequence,
      kind: Atom.to_string(stop.kind),
      address_text: stop.address_text,
      window_start: iso(stop.window_start),
      window_end: iso(stop.window_end),
      position: position,
      position_status: if(position, do: "recorded", else: "unresolved")
    }
  end

  defp stop_position(%Geo.Point{coordinates: {lng, lat}, srid: 4326})
       when is_number(lat) and lat >= -90 and lat <= 90 and
              is_number(lng) and lng >= -180 and lng <= 180,
       do: %{lat: lat, lng: lng}

  defp stop_position(_), do: nil
  defp ref(_kind, nil), do: nil
  defp ref(kind, id), do: %{kind: kind, id: id}
  defp iso(nil), do: nil
  defp iso(value), do: DateTime.to_iso8601(value)
end
