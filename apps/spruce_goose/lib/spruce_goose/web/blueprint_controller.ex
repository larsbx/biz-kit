defmodule SpruceGoose.Web.BlueprintController do
  @moduledoc """
  Applying a blueprint to a project
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md), for
  governance's tool (`mix coop.blueprint`).

      POST /api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/blueprints
           {"governance_key_id", "repository", "commit", "tree", "path", "manifest"}
           → 201 the application to sign
      POST …/blueprints/:held_id
           {"signature"} → 201 {event_id, global_seq}

  `manifest` is the blueprint's bytes, unpadded base64url, as the tool read
  them at the forge. The first request is signed by a governance key of the
  chapter (`Governance.Read`); nothing is applied without its signature.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Blueprints

  def prepare(conn, %{"chapter_id" => ch, "tenant_id" => t, "project_id" => p}) do
    with :ok <- governing(conn, ch),
         {:ok, body} <- json_body(conn),
         {:ok, signer} <- string(body["governance_key_id"]),
         {:ok, source} <- source(body),
         {:ok, bytes} <- bytes(body["manifest"]),
         {:ok, pending} <- Blueprints.prepare({ch, t, p}, source, bytes, signer) do
      held(conn, pending)
    else
      %Plug.Conn{} = refused -> refused
      error -> refuse(conn, error)
    end
  end

  def apply(conn, %{"chapter_id" => ch, "tenant_id" => t, "project_id" => p, "held_id" => id}) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Blueprints.apply({ch, t, p}, id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  defp source(body) do
    fields = ~w(repository commit tree path)

    if Enum.all?(fields, &is_binary(body[&1])),
      do: {:ok, Map.take(body, fields)},
      else: {:error, :bad_request}
  end
end
