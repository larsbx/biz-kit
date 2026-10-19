defmodule SpruceGoose.Web.GrantController do
  @moduledoc """
  Governance revocation of an operator or reviewer grant
  (docs/architecture/2026-10-19-device-revocation.md), normally through
  `mix coop.revoke <GRANT_ID>`, which holds the governance key.

      GET  /api/v1/grants/:id                          → the grant
      POST /api/v1/grants/:id/revocation               {"governance_key_id"} → 201 the revocation to sign
      POST /api/v1/grants/:id/revocation/:held_id      {"signature"} → 201 {event_id, global_seq}

  Nothing here revokes anything without a signature by a governance key
  declared on the ledger; the server signs nothing.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Devices

  def show(conn, %{"id" => id}) do
    case Devices.fetch(id) do
      {:ok, g} ->
        {chapter, tenant, project} = g.scope

        json(conn, %{
          grant_id: g.grant_id,
          role: g.role,
          principal_id: g.principal_id,
          chapter_id: chapter,
          tenant_id: tenant,
          project_id: project,
          key_id: g.key_id,
          label: g.label,
          active: g.active
        })

      error ->
        refuse(conn, error)
    end
  end

  def prepare(conn, %{"id" => id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["governance_key_id"]),
         {:ok, pending} <- Devices.prepare_governance_revocation(id, key_id) do
      held(conn, pending)
    else
      error -> refuse(conn, error)
    end
  end

  def revoke(conn, %{"id" => id, "held_id" => held_id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Devices.revoke(id, held_id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end
end
