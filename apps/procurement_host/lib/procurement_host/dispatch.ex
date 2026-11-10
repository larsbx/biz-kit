defmodule ProcurementHost.Dispatch do
  @moduledoc false
  import Plug.Conn
  alias CoopSubstrate.{Canonical, Log, Procurement, ProcurementDispatch, RestaurantDeliveryWork}
  alias CoopSubstrate.Protocol.Envelope
  alias ProcurementHost.Auth

  def code(context, id, phase) when phase in ["picked_up", "delivered"] do
    binding =
      :erlang.term_to_binary(
        {"procurement-delivery-v1", context.chapter_id, context.cooperative_id, id, phase}
      )

    :crypto.mac(:hmac, :sha256, context.secret_key_base, binding)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  def request(context, id, version) do
    Procurement.request_dispatch(
      context,
      id,
      version,
      digest(code(context, id, "picked_up")),
      digest(code(context, id, "delivered")),
      Auth.server()
    )
  end

  defp digest(code), do: Base.encode16(:crypto.hash(:sha256, code), case: :lower)

  def work(conn) do
    state = Procurement.state(Log.gate(Auth.server()))
    context = Auth.settings()
    chapter = context.chapter_id
    coop = context.cooperative_id
    key = fn tenant, id -> ProcurementDispatch.key(state, chapter, coop, tenant, id) end

    with {:ok, tenant, cursor} <-
           RestaurantDeliveryWork.authorize_scoped(
             conn.body_params,
             chapter,
             coop,
             :procurement,
             key
           ) do
      jobs = ProcurementDispatch.work(state, chapter, coop, tenant, cursor)
      next = if length(jobs) == 25, do: List.last(jobs).order_id
      json(conn, 200, %{jobs: jobs, next: next})
    else
      _ -> json(conn, 403, %{error: "forbidden"})
    end
  end

  def submit(conn) do
    context = Auth.settings()

    with %{"record" => encoded} = body
         when map_size(body) == 1 and is_binary(encoded) and
                byte_size(encoded) <= 4096 <- conn.body_params,
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         {:ok, term} <- Canonical.decode(bytes),
         {:ok,
          %Envelope{
            type: "ProcurementDispatchStepV1",
            payload: %{"cooperative_id" => coop},
            stream_id: nil,
            stream_seq: nil,
            global_seq: nil,
            prev_stream_hash: nil,
            prev_global_hash: nil,
            auth_ref: nil
          } = event} <- Envelope.from_full_record_term(term),
         true <- event.chapter_id == context.chapter_id and coop == context.cooperative_id do
      case Log.append(event, Auth.server()) do
        {:ok, [accepted]} ->
          json(conn, 201, %{event_id: accepted.event_id})

        {:error, {:reject, 0, :duplicate_delivery_step}} ->
          json(conn, 200, %{status: "already_admitted"})

        {:error, {:reject, 0, :procurement_dispatch_forbidden}} ->
          json(conn, 403, %{error: "forbidden"})

        {:error, {:reject, 0, reason}} when is_atom(reason) ->
          json(conn, 422, %{error: Atom.to_string(reason)})

        _ ->
          json(conn, 422, %{error: "not_admitted"})
      end
    else
      _ -> json(conn, 422, %{error: "invalid_delivery_record"})
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, :json.encode(body))
    |> halt()
  end
end
