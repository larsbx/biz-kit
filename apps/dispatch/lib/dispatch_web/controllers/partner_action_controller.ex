defmodule DispatchWeb.PartnerActionController do
  @moduledoc "Transport for partner submissions. Authorization remains in Ash."
  use Phoenix.Controller, formats: [:html, :json]
  import Plug.Conn
  alias Dispatch.Fleet.PartnerActions
  alias Dispatch.Idempotency
  alias DispatchWeb.ViewModels.{PartnerStopView, PartnerLoadView}

  def readiness(conn, params), do: submit(conn, params, :readiness)
  def document(conn, params), do: submit(conn, params, :document)
  def proposal(conn, params), do: submit(conn, params, :proposal)

  def stop(conn, %{"stop_id" => id}) do
    case PartnerStopView.build(conn.assigns.actor, id) do
      {:ok, view} -> json(conn, stop_json(view))
      _ -> refused(conn, :not_found)
    end
  end

  def load(conn, %{"load_id" => id}) do
    case PartnerLoadView.build(conn.assigns.actor, id) do
      {:ok, view} ->
        json(conn, %{
          load_id: view.load_id,
          external_reference: view.external_reference,
          status: to_string(view.status_summary.value),
          source: view.status_summary.source,
          occurred_at: view.status_summary.occurred_at,
          location_summary: nil,
          communications: view.communications,
          stops: view.stops
        })

      _ ->
        refused(conn, :not_found)
    end
  end

  defp submit(conn, %{"stop_id" => id} = params, kind) do
    actor = conn.assigns.actor
    body = Map.drop(params, ["_csrf_token", "idempotency_key", "stop_id"])
    key = List.first(get_req_header(conn, "idempotency-key")) || params["idempotency_key"]
    # Reauthorize BEFORE a stored response can be replayed. Ended relationships
    # cannot regain access through an old successful idempotency key.
    with {:ok, %Dispatch.Fleet.Stop{}} <- PartnerActions.stop(actor, id),
         true <- is_binary(key) and byte_size(key) in 1..200 do
      Idempotency.execute(actor, key, %{action: kind, stop_id: id, body: body}, fn ->
        case PartnerActions.submit(actor, id, kind, body) do
          {:ok, record} ->
            {:ok, 201,
             %{
               "id" => record.id,
               "stop_id" => id,
               "source" => "PARTICIPANT",
               "recorded_at" => DateTime.to_iso8601(record.recorded_at)
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end)
      |> case do
        {:ok, status, response} ->
          if api?(conn),
            do: conn |> put_status(status) |> json(response),
            else: redirect_after(conn, actor, id)

        {:error, reason} ->
          refused(conn, reason)
      end
    else
      false -> refused(conn, :idempotency_key_required)
      _ -> refused(conn, :not_found)
    end
  end

  defp submit(conn, _, _), do: refused(conn, :invalid_input)

  defp redirect_after(conn, actor, stop_id) do
    location =
      if actor.role_assignment.scope_type == :LOAD,
        do: "/loads/#{actor.role_assignment.scope_id}",
        else: "/partner/stops/#{stop_id}"

    conn |> put_resp_header("location", location) |> send_resp(303, "")
  end

  defp refused(conn, reason) do
    {status, code, message} = refusal(reason)

    if api?(conn) do
      conn
      |> put_resp_content_type("application/problem+json")
      |> send_resp(
        status,
        Jason.encode!(%{type: "about:blank", title: message, status: status, code: code})
      )
    else
      conn
      |> put_status(status)
      |> put_view(DispatchWeb.PortalHTML)
      |> render(:partner_refused, message: message)
    end
  end

  defp refusal(:not_found), do: {404, "NOT_FOUND", "Not found"}
  defp refusal(%Ash.Error.Forbidden{}), do: refusal(:not_found)

  defp refusal(:key_reused),
    do: {409, "IDEMPOTENCY_KEY_REUSED", "This form was used for another change. Reload the page."}

  defp refusal(:in_progress),
    do: {409, "IN_PROGRESS", "This change is still being made. Reload the page shortly."}

  defp refusal(:idempotency_key_required),
    do: {400, "IDEMPOTENCY_KEY_REQUIRED", "The form was incomplete. Reload the page."}

  defp refusal(reason) do
    if inspect(reason) =~ "STALE_VERSION" do
      {409, "STALE_VERSION",
       "The stop or readiness changed. Reload and review before submitting."}
    else
      {422, "INVALID_INPUT", "The change was not made. Check the values and reload the page."}
    end
  end

  defp api?(conn), do: String.starts_with?(conn.request_path, "/v1/")

  defp stop_json(v),
    do: %{
      stop_id: v.stop_id,
      load_id: v.load_id,
      kind: v.kind,
      address_text: v.address_text,
      window_start: v.window_start,
      window_end: v.window_end,
      version: v.version,
      readiness: v.readiness,
      readiness_summary: plain(v.readiness_summary),
      latest_readiness_id: v.latest_readiness_id,
      documents: v.documents,
      proposals: v.proposals
    }

  defp plain(nil), do: nil
  defp plain(value), do: Map.from_struct(value)
end
