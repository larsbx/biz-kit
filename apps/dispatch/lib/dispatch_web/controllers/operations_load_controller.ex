defmodule DispatchWeb.OperationsLoadController do
  @moduledoc "The carrier's read-only load record, separate from partner disclosure."

  use Phoenix.Controller, formats: [:html]

  alias Dispatch.Operations.LocationWork

  def show(conn, %{"load_id" => load_id}) do
    case LocationWork.load(conn.assigns.actor, load_id) do
      {:ok, actor, view} -> render(conn, :show, actor: actor, view: view)
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end
end
