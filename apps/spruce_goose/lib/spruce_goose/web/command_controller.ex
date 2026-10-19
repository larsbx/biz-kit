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

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Commands
  alias SpruceGoose.Web.AuthController

  def prepare(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, decision} <- decision(body),
         {:ok, key_id} <- string(body["key_id"]),
         {:ok, pending} <- Commands.prepare(principal, key_id, {c, t, p}, decision) do
      held(conn, pending)
    else
      error -> refuse(conn, error)
    end
  end

  def submit(conn, %{"id" => id}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Commands.submit(principal, id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  defp decision(%{"decision" => "accept", "suggestion_event_id" => id}) when is_binary(id),
    do: {:ok, {:accept, id}}

  defp decision(%{"decision" => "decline", "suggestion_event_id" => id, "reason" => r})
       when is_binary(id) and is_binary(r),
       do: {:ok, {:decline, id, r}}

  defp decision(_body), do: {:error, :bad_decision}
end
