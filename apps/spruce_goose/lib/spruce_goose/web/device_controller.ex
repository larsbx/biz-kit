defmodule SpruceGoose.Web.DeviceController do
  @moduledoc """
  A person's devices: enrolment
  (docs/architecture/2026-10-19-device-enrolment.md) and revocation
  (docs/architecture/2026-10-19-device-revocation.md). Transport only:
  `CoopSubstrate.Enrolments` and `CoopSubstrate.Devices` decide.

      GET  /api/v1/chapters/:c/tenants/:t/projects/:p/devices
           → [{id, kind, grant_id, key_id, label}], the person's devices: operator
             and reviewer grants (id: the grant's event ID) and administrator
             keys of the chapter (id: the key ID; docs/architecture/2026-10-19-own-devices.md)
      POST /api/v1/chapters/:c/tenants/:t/projects/:p/devices/:id/revocation
           {"key_id"} → 201 the revocation to sign with that device, submitted
           through POST /api/v1/commands/:id
      GET  /api/v1/chapters/:c/tenants/:t/projects/:p/devices/:key_id[?role=reviewer]
           → {status: "enrolled" | "pending" | "none", code?, expires_at?}
      POST /api/v1/chapters/:c/tenants/:t/projects/:p/devices
           {"key_id", "public_key" (base64url), "label", "role"?: "operator" | "reviewer"}
           → 201 {id, statement (base64url)}
      POST /api/v1/devices/challenges/:id  {"signature"} → 201 {code, expires_at}

  All need the session cookie. The device signs the statement it was given,
  after decoding it, as proof that it holds the key; the code then goes to an
  administrator. A role is operator unless the request names reviewer
  (docs/architecture/2026-10-19-execution.md); the same key may be enrolled
  in both.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.{Devices, Enrolments}
  alias SpruceGoose.Web.AuthController

  def index(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    case AuthController.principal(conn) do
      {:ok, principal, _id} -> json(conn, Devices.list(principal, {c, t, p}))
      error -> refuse(conn, error)
    end
  end

  def revoke(conn, %{
        "chapter_id" => c,
        "tenant_id" => t,
        "project_id" => p,
        "id" => id
      }) do
    with {:ok, principal, _id} <- AuthController.principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["key_id"]),
         {:ok, pending} <- Devices.prepare_revocation(principal, key_id, {c, t, p}, id) do
      held(conn, pending)
    else
      error -> refuse(conn, error)
    end
  end

  def status(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p, "key_id" => key_id}) do
    with {:ok, principal, _id} <- AuthController.principal(conn),
         {:ok, role} <- string(query(conn, "role") || "operator") do
      json(
        conn,
        case Enrolments.status(principal, {c, t, p}, key_id, role) do
          :enrolled ->
            %{status: "enrolled"}

          :none ->
            %{status: "none"}

          {:pending, code, expires_at} ->
            %{status: "pending", code: code, expires_at: expires_at}
        end
      )
    else
      error -> refuse(conn, error)
    end
  end

  def request(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    with {:ok, session, _id} <- AuthController.session(conn),
         {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["key_id"]),
         {:ok, pubkey} <- bytes(body["public_key"]),
         {:ok, label} <- string(body["label"]),
         {:ok, role} <- string(body["role"] || "operator"),
         {:ok, challenge} <-
           Enrolments.begin(
             session.principal,
             session.identity,
             {c, t, p},
             key_id,
             pubkey,
             label,
             role
           ) do
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
