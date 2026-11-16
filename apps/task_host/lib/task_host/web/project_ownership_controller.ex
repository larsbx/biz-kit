defmodule TaskHost.Web.ProjectOwnershipController do
  @moduledoc """
  Chapter-governed, signed legacy-project owner backfill.

  GET /api/v1/chapters/:chapter_id/ownerless_projects
      -> existing projects with tasks or grants but no accountable owner
  POST /api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/ownership/backfill/:principal_id
      -> governance-held signed batch with required owner-kind and grant events
  POST /api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/ownership/backfill/:principal_id/:held_id
      -> append the signed batch after revalidating authoritative ledger state

  An eligible operator key is supplied by the principal/device when needed.
  The server never creates or signs a device key, and no project history is
  overwritten. The prepare and list routes require a signed governance read.
  """

  use Phoenix.Controller, formats: [:json]

  import TaskHost.Web.Requests

  alias CoopSubstrate.ProjectOwnership

  def index(conn, %{"chapter_id" => chapter}) do
    with :ok <- governing(conn, chapter) do
      json(conn, ProjectOwnership.ownerless(chapter))
    end
  end

  def prepare(conn, %{
        "chapter_id" => chapter,
        "tenant_id" => tenant,
        "project_id" => project,
        "principal_id" => principal
      }) do
    with :ok <- governing(conn, chapter),
         {:ok, body} <- json_body(conn),
         {:ok, governance_key} <- string(body["governance_key_id"]),
         {:ok, device} <- device(body["operator_device"]),
         {:ok, held} <-
           ProjectOwnership.prepare_backfill(
             {chapter, tenant, project},
             principal,
             governance_key,
             device
           ) do
      held_batch(conn, held)
    else
      %Plug.Conn{} = refused -> refused
      error -> refuse(conn, error)
    end
  end

  def backfill(conn, %{
        "chapter_id" => chapter,
        "tenant_id" => tenant,
        "project_id" => project,
        "principal_id" => principal,
        "held_id" => id
      }) do
    with {:ok, body} <- json_body(conn),
         {:ok, signatures} <- bytes(body["signatures"]),
         {:ok, envs} <-
           ProjectOwnership.backfill({chapter, tenant, project}, principal, id, signatures) do
      appended(conn, envs)
    else
      error -> refuse(conn, error)
    end
  end

  defp device(nil), do: {:ok, nil}

  defp device(%{"key_id" => key, "pubkey" => pubkey} = fields)
       when map_size(fields) == 2 and is_binary(key) do
    with {:ok, decoded} <- bytes(pubkey) do
      {:ok, %{key_id: key, pubkey: decoded}}
    end
  end

  defp device(_), do: {:error, :bad_request}
end
