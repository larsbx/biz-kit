defmodule SpruceGoose.Web.PrincipalController do
  @moduledoc """
  Offboarding a principal (docs/architecture/2026-10-19-offboarding.md),
  normally through `mix coop.offboard <PRINCIPAL_ID>`, which holds the
  governance key.

      GET  /api/v1/principals/:id                         → what it holds, per project
      POST /api/v1/principals/:id/offboarding             {"governance_key_id", "chapter_id",
                                                           "tenant_id", "project_id"}
                                                          → 201 the offboarding to sign
      POST /api/v1/principals/:id/offboarding/:held_id    {"signature"} → 201 {event_id, global_seq}
      POST /api/v1/principals/:id/chapter_offboarding     {"governance_key_id", "chapter_id"}
                                                          → 201 {id, commands: [{type, payload, signing_bytes}]}
      POST /api/v1/principals/:id/chapter_offboarding/:held_id
                                                          {"signatures": [...]} → 201 {events}

  From the whole chapter (docs/architecture/2026-10-19-chapter-offboarding.md):
  every project the principal holds something in, and their administrator
  keys there, as one batch signed command by command and appended at once.

  What a principal holds is for administrators only, and preparing an
  offboarding would tell whether it holds anything, so both requests are
  signed by a governance key (`Governance.Read`) and answer for the chapters
  it governs. Nothing here ends anything without a signature by a governance
  key declared on the ledger; the server signs nothing.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Offboarding

  def show(conn, %{"id" => id}) do
    case governance_read(conn) do
      {:ok, chapters} -> json(conn, Offboarding.fetch(id, chapters))
      {:unauthorized, reason} -> unauthorized(conn, reason)
    end
  end

  def prepare(conn, %{"id" => id}) do
    with {:ok, chapters} <- governance_read(conn),
         {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["governance_key_id"]),
         {:ok, chapter} <- string(body["chapter_id"]),
         true <- chapter in chapters or {:unauthorized, :not_governance},
         {:ok, tenant} <- string(body["tenant_id"]),
         {:ok, project} <- string(body["project_id"]),
         {:ok, pending} <- Offboarding.prepare(id, {chapter, tenant, project}, key_id) do
      held(conn, pending)
    else
      {:unauthorized, reason} -> unauthorized(conn, reason)
      error -> refuse(conn, error)
    end
  end

  def prepare_chapter(conn, %{"id" => id}) do
    with {:ok, chapters} <- governance_read(conn),
         {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["governance_key_id"]),
         {:ok, chapter} <- string(body["chapter_id"]),
         true <- chapter in chapters or {:unauthorized, :not_governance},
         {:ok, batch} <- Offboarding.prepare_chapter(id, chapter, key_id) do
      held_batch(conn, batch)
    else
      {:unauthorized, reason} -> unauthorized(conn, reason)
      error -> refuse(conn, error)
    end
  end

  def offboard_chapter(conn, %{"id" => id, "held_id" => held_id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signatures} <- bytes(body["signatures"]),
         {:ok, envs} <- Offboarding.offboard_chapter(id, held_id, signatures) do
      appended(conn, envs)
    else
      error -> refuse(conn, error)
    end
  end

  def offboard(conn, %{"id" => id, "held_id" => held_id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Offboarding.offboard(id, held_id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end
end
