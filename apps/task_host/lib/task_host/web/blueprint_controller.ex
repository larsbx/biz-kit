defmodule TaskHost.Web.BlueprintController do
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

  import TaskHost.Web.Requests

  alias CoopSubstrate.Blueprints
  alias CoopSubstrate.ULID

  def prepare(conn, params), do: prepare(conn, params, :apply)
  def prepare_registration(conn, params), do: prepare(conn, params, :register)

  defp prepare(conn, %{"chapter_id" => ch, "tenant_id" => t, "project_id" => p}, mode) do
    with :ok <- governing(conn, ch),
         {:ok, body} <- json_body(conn),
         {:ok, signer} <- string(body["governance_key_id"]),
         {:ok, source} <- source(body, mode),
         {:ok, bytes} <- bytes(body["manifest"]),
         {:ok, pending} <- Blueprints.prepare({ch, t, p}, source, bytes, signer, mode) do
      held(conn, pending)
    else
      %Plug.Conn{} = refused -> refused
      error -> refuse(conn, error)
    end
  end

  def apply(conn, params), do: submit(conn, params, :apply)
  def register(conn, params), do: submit(conn, params, :register)

  defp submit(
         conn,
         %{"chapter_id" => ch, "tenant_id" => t, "project_id" => p, "held_id" => id},
         mode
       ) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Blueprints.submit({ch, t, p}, id, signature, mode) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  defp source(body, mode) do
    fields = ~w(repository commit tree path)

    with true <- Enum.all?(fields, &is_binary(body[&1])),
         {:ok, registration} <- registration(body, mode) do
      {:ok, Map.merge(Map.take(body, fields), registration)}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp registration(body, mode) do
    case Map.fetch(body, "registration_event_id") do
      :error ->
        {:ok, %{}}

      {:ok, id} when mode == :apply ->
        if ULID.valid?(id), do: {:ok, %{"registration_event_id" => id}}, else: :error

      _ ->
        :error
    end
  end
end
