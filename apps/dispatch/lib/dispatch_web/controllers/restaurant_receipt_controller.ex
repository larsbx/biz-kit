defmodule DispatchWeb.RestaurantReceiptController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  alias Dispatch.{RestaurantAutomation, RestaurantReceipts}
  alias Dispatch.Operations.Trips

  def form(conn, _), do: page(conn, nil)

  def submit(conn, _) do
    case RestaurantReceipts.submit(conn.assigns.actor, conn.body_params) do
      {:ok, _} ->
        page(conn, "Handoff recorded.")

      {:error, _} ->
        page(put_status(conn, 422), "Handoff refused. Check your assignment and code.")
    end
  end

  defp page(conn, message) do
    with true <-
           RestaurantAutomation.enabled?(:restaurant) or
             RestaurantAutomation.enabled?(:procurement),
         {:ok, trips} <- Trips.mine(conn.assigns.actor) do
      token = Phoenix.Controller.get_csrf_token()

      options =
        for %{assignment: %{id: id, status: :ACTIVE}} <- trips do
          ["<option value=\"", id, "\">", id, "</option>"]
        end

      html(conn, [
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Delivery handoff</title>",
        "<h1>Delivery handoff</h1>",
        if(message, do: ["<p role=\"status\">", message, "</p>"], else: []),
        "<form method=\"post\" action=\"/ui/restaurant-receipts\">",
        "<input type=\"hidden\" name=\"_csrf_token\" value=\"",
        token,
        "\">",
        "<label>Active assignment <select required name=\"assignment_id\">",
        options,
        "</select></label>",
        "<label>Handoff <select name=\"phase\"><option value=\"picked_up\">Pickup</option>",
        "<option value=\"delivered\">Drop-off</option></select></label>",
        "<label>Handoff code <input required name=\"handoff_token\" maxlength=\"22\" autocomplete=\"off\"></label>",
        "<button>Record handoff</button></form></html>"
      ])
    else
      _ -> conn |> put_status(403) |> text("Delivery handoff is unavailable.")
    end
  end
end
