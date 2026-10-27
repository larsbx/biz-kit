defmodule DispatchWeb.OperationsController do
  @moduledoc """
  The carrier's dispatch board over `/v1/operations` (`Dispatch.Operations.Board`):
  its loads, stops and trips, and the fleet trips are planned with.

  Every write honours `Idempotency-Key` (Section 24) and answers with the whole
  load it changed, so a client never has to stitch a partial response back
  into what it holds.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Dispatch.Idempotency
  alias Dispatch.Operations.Board
  alias DispatchWeb.Problem
  alias DispatchWeb.Schemas

  tags(["operations"])

  @problem {"Problem", "application/problem+json", Schemas.Problem}
  @load {"Load", "application/json", Schemas.BoardLoad}
  @role [
    "x-role-assignment-id": [
      in: :header,
      type: :string,
      description: "Selects which held role assignment the request acts under."
    ]
  ]
  @idempotency [
    "idempotency-key": [
      in: :header,
      type: :string,
      description: "Replays the first response for a retried request (Section 24)."
    ]
  ]
  @load_id [load_id: [in: :path, type: :string, required: true]]
  @refusals [
    forbidden: @problem,
    not_found: @problem,
    conflict: @problem,
    unprocessable_entity: @problem
  ]

  operation(:index,
    summary: "The organization's loads with their stops and trips",
    security: [%{"bearerAuth" => []}],
    parameters: @role,
    responses: [ok: {"Loads", "application/json", Schemas.BoardLoadList}, forbidden: @problem]
  )

  operation(:show,
    summary: "One of the organization's loads",
    security: [%{"bearerAuth" => []}],
    parameters: @role ++ @load_id,
    responses: [ok: @load, forbidden: @problem, not_found: @problem]
  )

  operation(:fleet,
    summary: "The drivers, vehicles and trailers a trip can be planned with",
    security: [%{"bearerAuth" => []}],
    parameters: @role,
    responses: [ok: {"Fleet", "application/json", Schemas.Fleet}, forbidden: @problem]
  )

  operation(:create,
    summary: "Create a DRAFT load with this organization as the carrier",
    security: [%{"bearerAuth" => []}],
    parameters: @role ++ @idempotency,
    request_body: {"Load", "application/json", Schemas.LoadInput},
    responses: [created: @load] ++ @refusals
  )

  operation(:update,
    summary: "Change a load's commodity text and reference",
    security: [%{"bearerAuth" => []}],
    parameters: @role ++ @idempotency ++ @load_id,
    request_body: {"Load", "application/json", Schemas.LoadInput},
    responses: [ok: @load] ++ @refusals
  )

  operation(:add_stop,
    summary: "Append a stop to a load",
    security: [%{"bearerAuth" => []}],
    parameters: @role ++ @idempotency ++ @load_id,
    request_body: {"Stop", "application/json", Schemas.StopInput},
    responses: [created: @load] ++ @refusals
  )

  operation(:plan,
    summary: "Plan a trip for a load",
    security: [%{"bearerAuth" => []}],
    parameters: @role ++ @idempotency ++ @load_id,
    request_body: {"Trip", "application/json", Schemas.TripInput},
    responses: [created: @load] ++ @refusals
  )

  operation(:transition,
    summary: "Activate, complete or cancel a trip",
    security: [%{"bearerAuth" => []}],
    parameters:
      @role ++
        @idempotency ++
        [assignment_id: [in: :path, type: :string, required: true]],
    request_body: {"Transition", "application/json", Schemas.TripTransition},
    responses: [ok: @load] ++ @refusals
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case Board.loads(conn.assigns.actor) do
      {:ok, loads} -> json(conn, %{loads: Enum.map(loads, &load/1)})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"load_id" => id}) do
    case Board.load(conn.assigns.actor, id) do
      {:ok, found} -> json(conn, load(found))
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @spec fleet(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def fleet(conn, _params) do
    case Board.fleet(conn.assigns.actor) do
      {:ok, %{drivers: drivers, vehicles: vehicles, trailers: trailers}} ->
        json(conn, %{
          drivers: Enum.map(drivers, &%{participant_id: &1.id, public_name: &1.public_name}),
          vehicles: Enum.map(vehicles, &unit/1),
          trailers: Enum.map(trailers, &unit/1)
        })

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params),
    do: write(conn, 201, &Board.create_load(&1, conn.body_params))

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"load_id" => id}),
    do: write(conn, 200, &Board.update_load(&1, id, conn.body_params))

  @spec add_stop(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def add_stop(conn, %{"load_id" => id}),
    do: write(conn, 201, &Board.add_stop(&1, id, conn.body_params))

  @spec plan(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def plan(conn, %{"load_id" => id}),
    do: write(conn, 201, &Board.plan(&1, id, conn.body_params))

  @spec transition(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def transition(conn, %{"assignment_id" => id}) do
    body = conn.body_params

    write(conn, 200, &Board.transition(&1, id, body["action"], body["expected_version"]))
  end

  defp write(conn, status, change) do
    actor = conn.assigns.actor

    Idempotency.execute(actor, idempotency_key(conn), conn.body_params, fn ->
      case change.(actor) do
        {:ok, changed} -> {:ok, status, load(changed)}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, status, body} -> conn |> put_status(status) |> json(body)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _rest] -> key
      [] -> nil
    end
  end

  defp refuse(conn, :forbidden),
    do: Problem.send(conn, 403, "FORBIDDEN", "This role assignment cannot do that.")

  defp refuse(conn, :not_found),
    do: Problem.send(conn, 404, "NOT_FOUND", "No such load or trip in this organization.")

  defp refuse(conn, :stale),
    do: Problem.send(conn, 409, "STALE_VERSION", "The record changed since it was read.")

  defp refuse(conn, {:invalid, detail}),
    do: Problem.send(conn, 422, "INVALID", detail)

  defp refuse(conn, :key_reused),
    do:
      Problem.send(
        conn,
        409,
        "IDEMPOTENCY_KEY_REUSED",
        "This idempotency key was used for a different request."
      )

  defp refuse(conn, :in_progress),
    do: Problem.send(conn, 409, "IDEMPOTENCY_IN_PROGRESS", "The first request is still running.")

  defp load(load) do
    %{
      load_id: load.id,
      external_reference: load.external_reference,
      commodity_text: load.commodity_text,
      status: load.status,
      created_at: load.created_at,
      version: load.version,
      stops: Enum.map(load.stops, &stop/1),
      trips: Enum.map(load.assignments, &trip/1)
    }
  end

  defp stop(stop) do
    %{
      stop_id: stop.id,
      sequence: stop.sequence,
      kind: stop.kind,
      address_text: stop.address_text,
      window_start: stop.window_start,
      window_end: stop.window_end,
      contact_name: stop.contact_name,
      contact_phone_e164: stop.contact_phone_e164
    }
  end

  defp trip(trip) do
    %{
      assignment_id: trip.id,
      operator_participant_id: trip.operator_participant_id,
      vehicle_id: trip.vehicle_id,
      trailer_id: trip.trailer_id,
      status: trip.status,
      starts_at: trip.starts_at,
      ends_at: trip.ends_at,
      version: trip.version
    }
  end

  defp unit(unit), do: %{id: unit.id, unit_number: unit.unit_number, plate: unit.plate}
end
