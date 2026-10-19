defmodule SpruceGoose.Web.AdministratorController do
  @moduledoc """
  A chapter's administrators, its governance keys
  (docs/architecture/2026-10-19-administration.md), for an administrator's
  browser or a script holding a governance key.

      GET  /api/v1/chapters/:chapter_id/administrators
           → [{key_id, principal_id}]
      POST /api/v1/chapters/:chapter_id/administrators/:key_id/revocation
           {"governance_key_id", "reason"} → 201 the revocation to sign
      POST /api/v1/chapters/:chapter_id/administrators/:key_id/revocation/:held_id
           {"signature"} → 201 {event_id, global_seq}

  The first two are signed by a governance key of that chapter
  (`Governance.Read`). Nothing here revokes anything without a governance
  signature; the server signs nothing.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Administrators

  def index(conn, %{"chapter_id" => chapter}) do
    with {:ok, chapters} <- governance_read(conn),
         true <- chapter in chapters or {:unauthorized, :not_governance} do
      json(conn, Administrators.list(chapter))
    else
      {:unauthorized, reason} -> unauthorized(conn, reason)
    end
  end

  def prepare(conn, %{"chapter_id" => chapter, "key_id" => key_id}) do
    with {:ok, chapters} <- governance_read(conn),
         true <- chapter in chapters or {:unauthorized, :not_governance},
         {:ok, body} <- json_body(conn),
         {:ok, signer} <- string(body["governance_key_id"]),
         {:ok, reason} <- string(body["reason"]),
         {:ok, pending} <- Administrators.prepare_revocation(chapter, key_id, reason, signer) do
      held(conn, pending)
    else
      {:unauthorized, reason} -> unauthorized(conn, reason)
      error -> refuse(conn, error)
    end
  end

  def revoke(conn, %{"chapter_id" => chapter, "key_id" => key_id, "held_id" => held_id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Administrators.revoke(chapter, key_id, held_id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end
end
