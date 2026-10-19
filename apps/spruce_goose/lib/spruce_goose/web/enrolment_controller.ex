defmodule SpruceGoose.Web.EnrolmentController do
  @moduledoc """
  An administrator approves a device enrolment by its code
  (docs/architecture/2026-10-19-device-enrolment.md), normally through
  `mix coop.enrol <code>`, which holds the governance key.

      GET  /api/v1/enrolments/:code                 → the request
      POST /api/v1/enrolments/:code/approval        {"governance_key_id"} → 201 the grant to sign
      POST /api/v1/enrolments/:code/approval/:id    {"signature"} → 201 {event_id, global_seq}

  The code is the capability: it names one request, expires, and is used
  once. Nothing here can grant access without a signature by a governance key
  declared on the ledger; the server signs nothing.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Enrolments

  def show(conn, %{"code" => code}) do
    case Enrolments.fetch(code) do
      {:ok, r} ->
        {chapter, tenant, project} = r.scope

        json(conn, %{
          code: r.code,
          principal_id: r.principal_id,
          identity: r.identity,
          chapter_id: chapter,
          tenant_id: tenant,
          project_id: project,
          key_id: r.key_id,
          public_key: encode(r.pubkey),
          label: r.label,
          expires_at: r.expires_at
        })

      error ->
        refuse(conn, error)
    end
  end

  def prepare(conn, %{"code" => code}) do
    with {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["governance_key_id"]),
         {:ok, pending} <- Enrolments.prepare_approval(code, key_id) do
      held(conn, pending)
    else
      error -> refuse(conn, error)
    end
  end

  def approve(conn, %{"code" => code, "id" => id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, grant} <- Enrolments.approve(code, id, signature) do
      appended(conn, grant)
    else
      error -> refuse(conn, error)
    end
  end
end
