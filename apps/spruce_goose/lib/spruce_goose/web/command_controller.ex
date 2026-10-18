defmodule SpruceGoose.Web.CommandController do
  @moduledoc """
  A person's decision on a suggestion, signed on their device
  (docs/architecture/2026-10-18-decide.md). Transport only: `CoopSubstrate.Commands`
  prepares and admits the command; the ledger checks it as any operator
  command.

      POST /api/v1/chapters/:c/tenants/:t/projects/:p/commands
           {"decision": "accept" | "decline", "suggestion_event_id", "reason"?, "key_id"}
           → 201 {id, type, payload, signing_bytes (base64url), expires_at}
      POST /api/v1/commands/:id  {"signature": base64url}
           → 201 {event_id, global_seq}

  Both need the session cookie, and only accept `application/json`: a
  cross-site form cannot send it, and SameSite=Lax keeps the cookie off
  cross-site POSTs anyway. The device must sign the bytes it was given; the
  server holds no key.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  require Logger

  alias CoopSubstrate.Commands
  alias SpruceGoose.Web.AuthController

  def prepare(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, decision} <- decision(body),
         {:ok, pending} <- Commands.prepare(principal, body["key_id"] || "", {c, t, p}, decision) do
      conn
      |> put_status(201)
      |> json(%{
        id: pending.id,
        type: pending.type,
        payload: pending.payload,
        signing_bytes: Base.url_encode64(pending.signing_bytes, padding: false),
        expires_at: pending.expires_at
      })
    else
      error -> refuse(conn, error)
    end
  end

  def submit(conn, %{"id" => id}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, signature} <- Base.url_decode64(body["signature"] || "", padding: false),
         {:ok, env} <- Commands.submit(principal, id, signature) do
      conn |> put_status(201) |> json(%{event_id: env.event_id, global_seq: env.global_seq})
    else
      :error -> refuse(conn, {:error, :bad_signature_encoding})
      error -> refuse(conn, error)
    end
  end

  defp decision(%{"decision" => "accept", "suggestion_event_id" => id}) when is_binary(id),
    do: {:ok, {:accept, id}}

  defp decision(%{"decision" => "decline", "suggestion_event_id" => id, "reason" => r})
       when is_binary(id) and is_binary(r),
       do: {:ok, {:decline, id, r}}

  defp decision(_body), do: {:error, :bad_decision}

  # The endpoint's parsers have usually read the body already; the router
  # alone (as in tests) leaves it unread.
  defp json_body(conn) do
    with ["application/json" <> _] <- get_req_header(conn, "content-type"),
         {:ok, %{} = body} <- body_params(conn) do
      {:ok, body}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp body_params(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    with {:ok, raw, _conn} <- read_body(conn), do: Jason.decode(raw)
  end

  defp body_params(%{body_params: params}), do: {:ok, params}

  defp refuse(conn, {:error, reason}) do
    {status, code} =
      case reason do
        r when r in [:no_credentials, :unknown_session, :expired, :unbound] ->
          {401, "unauthorized"}

        :no_operator_grant ->
          {403, "no_operator_grant"}

        r when r in [:bad_request, :bad_decision, :bad_signature_encoding] ->
          {400, Atom.to_string(r)}

        :unknown_command ->
          {404, "unknown_command"}

        {:invalid_signature, _} ->
          {422, "invalid_signature"}

        r when r in [:unknown_suggestion, :suggestion_not_pending, :unknown_task] ->
          {409, Atom.to_string(r)}

        _ ->
          {409, "refused_by_ledger"}
      end

    Logger.info("command refused: #{inspect(reason)}")
    conn |> put_status(status) |> json(%{error: code})
  end
end
