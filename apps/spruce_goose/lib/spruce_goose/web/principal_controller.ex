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

  What a principal holds is for administrators only, and preparing an
  offboarding would tell whether it holds anything, so both requests are
  signed by a governance key (`Governance.Read`) and answer for the chapters
  it governs. Nothing here ends anything without a signature by a governance
  key declared on the ledger; the server signs nothing.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn
  import SpruceGoose.Web.Requests

  require Logger

  alias CoopSubstrate.Governance.Read
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

  def offboard(conn, %{"id" => id, "held_id" => held_id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Offboarding.offboard(id, held_id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  @fields ~w(key ts nonce sig)

  defp governance_read(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         "CoopGovernance " <> params <- header,
         fields = Map.new(Regex.scan(~r/(\w+)="([^"]*)"/, params), fn [_, k, v] -> {k, v} end),
         true <- Enum.all?(@fields, &Map.has_key?(fields, &1)),
         {ts, ""} <- Integer.parse(fields["ts"]),
         {:ok, signature} <- Base.url_decode64(fields["sig"], padding: false) do
      Read.authorize(
        %{
          method: conn.method,
          path: conn.request_path,
          timestamp_ms: ts,
          nonce: fields["nonce"],
          key_id: fields["key"]
        },
        signature
      )
      |> case do
        {:ok, chapters} -> {:ok, chapters}
        {:error, reason} -> {:unauthorized, reason}
      end
    else
      _ -> {:unauthorized, :malformed_authorization}
    end
  end

  defp unauthorized(conn, reason) do
    Logger.info("governance read refused: #{inspect(reason)}")

    conn
    |> put_resp_header("www-authenticate", "CoopGovernance")
    |> put_status(401)
    |> json(%{error: "unauthorized"})
  end
end
