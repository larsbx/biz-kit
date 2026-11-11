defmodule DispatchWeb.FleetLocationsController do
  @moduledoc "Same-origin location reads under the existing selected portal session."

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Dispatch.Operations.LocationSnapshot
  alias DispatchWeb.Streams.{Locations, Transport}

  def index(conn, _params) do
    case LocationSnapshot.build(conn.assigns.actor) do
      {:ok, result} -> json(conn, result.snapshot)
      {:error, :not_found} -> not_found(conn)
    end
  end

  def stream(conn, _params) do
    actor = conn.assigns.actor
    topic = "operations:#{actor.role_assignment.organization_id}"
    last_event_id = List.first(get_req_header(conn, "last-event-id"))

    case Transport.serve(
           conn,
           Locations,
           topic,
           fn -> Locations.open(actor, last_event_id: last_event_id) end,
           authorize: &DispatchWeb.StreamController.authorized_tick/2
         ) do
      {:error, :not_found} -> not_found(conn)
      served -> served
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})
end
