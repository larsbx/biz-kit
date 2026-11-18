defmodule RestaurantHost.Web.DeliveryController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  alias CoopSubstrate.{Canonical, Log, RestaurantDeliveryWork}
  alias CoopSubstrate.Protocol.Envelope
  alias RestaurantCore.Admission
  alias RestaurantHost.Restaurant

  def work(conn, _) do
    r = Restaurant.current()
    state = Log.gate().restaurant

    with {:ok, tenant, cursor} <-
           RestaurantDeliveryWork.authorize(conn.body_params, state, r.chapter, r.merchant) do
      jobs = Admission.delivery_work(state, r.chapter, r.merchant, tenant, cursor)
      next = if length(jobs) == 25, do: List.last(jobs).order_id
      conn |> put_resp_header("cache-control", "no-store") |> json(%{jobs: jobs, next: next})
    else
      _ -> conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  def submit(conn, _) do
    r = Restaurant.current()

    with %{"record" => encoded} = body when map_size(body) == 1 and is_binary(encoded) <-
           conn.body_params,
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         {:ok, term} <- Canonical.decode(bytes),
         {:ok, %Envelope{type: "RestaurantDeliveryStepV1"} = event} <-
           Envelope.from_full_record_term(term),
         true <-
           is_map(event.payload) and event.chapter_id == r.chapter and
             event.payload["merchant_id"] == r.merchant,
         true <- unassigned?(event) do
      case Log.append(event) do
        {:ok, [admitted]} ->
          conn |> put_status(201) |> json(%{event_id: admitted.event_id})

        {:error, {:reject, 0, :duplicate_delivery_step}} ->
          json(conn, %{status: "already_admitted"})

        {:error, {:reject, 0, :forbidden}} ->
          conn |> put_status(403) |> json(%{error: "forbidden"})

        {:error, {:reject, 0, reason}} when is_atom(reason) ->
          conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})

        {:error, _} ->
          conn |> put_status(422) |> json(%{error: "not_admitted"})
      end
    else
      _ -> conn |> put_status(422) |> json(%{error: "invalid_delivery_record"})
    end
  end

  defp unassigned?(event) do
    is_nil(event.stream_id) and is_nil(event.stream_seq) and is_nil(event.global_seq) and
      is_nil(event.prev_stream_hash) and is_nil(event.prev_global_hash) and is_nil(event.auth_ref)
  end
end
