defmodule DispatchWeb.AssignmentController do
  @moduledoc """
  The caller's own trips (`Dispatch.Operations.Trips`): canonical
  `GET /v1/me/assignments` and the DRIVER projection `GET /v1/driver/assignments`.
  """

  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  import DispatchWeb.LocationJSON, only: [consent: 1]

  alias Dispatch.Operations.Trips
  alias DispatchWeb.Problem

  tags(["assignments"])

  @problem {"Problem", "application/problem+json", DispatchWeb.Schemas.Problem}
  @parameters [
    "x-role-assignment-id": [
      in: :header,
      type: :string,
      description: "Selects which held role assignment the request acts under."
    ]
  ]

  operation(:mine,
    summary: "Your trips not yet over",
    description: """
    PLANNED and ACTIVE assignments not past their end, soonest first, each with
    the location consent covering it now. After a reboot this is the server's
    word that a persisted consent is still valid (Section 25.3).
    """,
    security: [%{"bearerAuth" => []}],
    parameters: @parameters,
    responses: [
      ok: {"Trips", "application/json", DispatchWeb.Schemas.TripList},
      forbidden: @problem
    ]
  )

  operation(:driver,
    summary: "Your trips not yet over (DRIVER compatibility projection)",
    description: "Identical behaviour to /v1/me/assignments.",
    security: [%{"bearerAuth" => []}],
    parameters: @parameters,
    responses: [
      ok: {"Trips", "application/json", DispatchWeb.Schemas.TripList},
      forbidden: @problem
    ]
  )

  @spec mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mine(conn, _params), do: trips(conn)

  @spec driver(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def driver(conn, _params), do: trips(conn)

  defp trips(conn) do
    case Trips.mine(conn.assigns.actor) do
      {:ok, trips} ->
        json(conn, %{assignments: Enum.map(trips, &trip/1)})

      {:error, :forbidden} ->
        Problem.send(conn, 403, "FORBIDDEN", "This role assignment cannot read its own trips.")
    end
  end

  defp trip(%{assignment: a, consent: grant}) do
    %{
      assignment_id: a.id,
      load_id: a.load_id,
      status: a.status,
      starts_at: a.starts_at,
      ends_at: a.ends_at,
      location_consent: grant && consent(grant)
    }
  end
end
