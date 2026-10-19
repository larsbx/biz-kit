defmodule SpruceGoose.Web.CommandController do
  @moduledoc """
  A person's decision on a suggestion (docs/architecture/2026-10-18-decide.md)
  or lifecycle step (docs/architecture/2026-10-19-lifecycle.md,
  2026-10-19-execution.md), signed on their device. Transport only: `CoopSubstrate.Commands`
  prepares and admits the command; the ledger checks it as any operator
  command.

      POST /api/v1/chapters/:c/tenants/:t/projects/:p/commands
           {"decision": "accept" | "amend" | "decline", "suggestion_event_id", "key_id",
            "edits"? (amend: the fields the person changed), "reason"? (decline)}
        or {"action": "propose" | "queue", "task_id", "key_id"}
           {"action": "acknowledge_sop", "task_id", "custody_receipt_id", "key_id"}
           {"action": "ready", "task_id", "custody_receipts": {name: receipt id}, "key_id"}
           {"action": "revoke_delegation", "delegation_event_id", "key_id"}
           {"action": "record_custody", "artifact_digest": hex SHA-256, "key_id"}
           {"action": "start", "task_id", "key_id"}
           {"action": "submit_evidence", "task_id", "custody_receipts": {criterion: receipt id}, "key_id"}
           {"action": "review", "task_id", "decision": "accept" | "refuse", "reason", "key_id"}
             (signed with a reviewer device's key)
           {"action": "complete", "task_id", "review_event_id", "key_id"}
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
         {:ok, decision} <- command(body),
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

  defp command(%{"action" => _} = body), do: action(body)
  defp command(body), do: decision(body)

  defp action(%{"action" => a, "task_id" => t})
       when a in ~w(propose queue start) and is_binary(t),
       do: {:ok, {String.to_existing_atom(a), t}}

  defp action(%{"action" => "acknowledge_sop", "task_id" => t, "custody_receipt_id" => r})
       when is_binary(t) and is_binary(r),
       do: {:ok, {:acknowledge_sop, t, r}}

  defp action(%{"action" => a, "task_id" => t, "custody_receipts" => rs})
       when a in ~w(ready submit_evidence) and is_binary(t) and is_map(rs) do
    if Enum.all?(rs, fn {_, id} -> is_binary(id) end),
      do: {:ok, {String.to_existing_atom(a), t, rs}},
      else: {:error, :bad_action}
  end

  defp action(%{"action" => "review", "task_id" => t, "decision" => d, "reason" => r})
       when is_binary(t) and is_binary(d) and is_binary(r),
       do: {:ok, {:review, t, d, r}}

  defp action(%{"action" => "complete", "task_id" => t, "review_event_id" => r})
       when is_binary(t) and is_binary(r),
       do: {:ok, {:complete, t, r}}

  defp action(%{"action" => "revoke_delegation", "delegation_event_id" => d}) when is_binary(d),
    do: {:ok, {:revoke_delegation, d}}

  defp action(%{"action" => "record_custody", "artifact_digest" => hex}) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, <<_::256>> = digest} -> {:ok, {:record_custody, digest}}
      _ -> {:error, :bad_action}
    end
  end

  defp action(_body), do: {:error, :bad_action}

  defp decision(%{"decision" => "accept", "suggestion_event_id" => id}) when is_binary(id),
    do: {:ok, {:accept, id}}

  defp decision(%{"decision" => "amend", "suggestion_event_id" => id, "edits" => edits})
       when is_binary(id) and is_map(edits),
       do: {:ok, {:amend, id, edits}}

  defp decision(%{"decision" => "decline", "suggestion_event_id" => id, "reason" => r})
       when is_binary(id) and is_binary(r),
       do: {:ok, {:decline, id, r}}

  defp decision(_body), do: {:error, :bad_decision}
end
