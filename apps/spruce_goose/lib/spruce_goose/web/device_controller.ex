defmodule SpruceGoose.Web.DeviceController do
  @moduledoc """
  A person asks for their device to be enrolled
  (docs/architecture/2026-10-19-device-enrolment.md). Transport only:
  `CoopSubstrate.Enrolments` decides.

      GET  /api/v1/chapters/:c/tenants/:t/projects/:p/devices/:key_id
           → {status: "enrolled" | "pending" | "none", code?, expires_at?}
      POST /api/v1/chapters/:c/tenants/:t/projects/:p/devices
           {"key_id", "public_key" (base64url), "label"} → 201 {id, statement (base64url)}
      POST /api/v1/devices/challenges/:id  {"signature"} → 201 {code, expires_at}

  All need the session cookie. The device signs the statement it was given,
  after decoding it, as proof that it holds the key; the code then goes to an
  administrator.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Enrolments
  alias SpruceGoose.Web.AuthController

  def status(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p, "key_id" => key_id}) do
    case AuthController.principal(conn) do
      {:ok, principal, _id} ->
        json(
          conn,
          case Enrolments.status(principal, {c, t, p}, key_id) do
            :enrolled ->
              %{status: "enrolled"}

            :none ->
              %{status: "none"}

            {:pending, code, expires_at} ->
              %{status: "pending", code: code, expires_at: expires_at}
          end
        )

      error ->
        refuse(conn, error)
    end
  end

  def request(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    with {:ok, session, _id} <- AuthController.session(conn),
         {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["key_id"]),
         {:ok, pubkey} <- bytes(body["public_key"]),
         {:ok, label} <- string(body["label"]),
         {:ok, challenge} <-
           Enrolments.begin(session.principal, session.identity, {c, t, p}, key_id, pubkey, label) do
      conn |> put_status(201) |> json(%{id: challenge.id, statement: encode(challenge.statement)})
    else
      error -> refuse(conn, error)
    end
  end

  def prove(conn, %{"id" => id}) do
    with {:ok, principal, _id} <- AuthController.principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, request} <- Enrolments.prove(principal, id, signature) do
      conn |> put_status(201) |> json(request)
    else
      error -> refuse(conn, error)
    end
  end
end
