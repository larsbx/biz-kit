defmodule TaskHost.Web.KnowledgeController do
  @moduledoc """
  Read the published BizOps reference snapshot through Operations access.

  The corpus is shared reference material, intentionally published with this
  release. A current read grant for at least one configured Operations
  workspace is required by this host. Folder names are classification, never
  document permissions. Neither reading a procedure nor its metadata applies
  a blueprint, grants authority or changes a task.
  """
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias BizKit.Identity
  alias BizOpsKB.Catalog
  alias BizOpsKB.Workflows
  alias CoopSubstrate.Log
  alias TaskHost.Operations
  alias TaskHost.Web.AuthController

  def index(conn, _params) do
    conn = private_response(conn)

    with {:ok, principal, session} <- authenticate(conn),
         :ok <- operations_access(principal),
         conn = fetch_query_params(conn),
         {:ok, options} <- search_options(conn.query_params),
         {:ok, catalog} <- load_catalog(),
         result = Catalog.search(catalog, options),
         workflows = workflow_index(catalog),
         :ok <- still_authorized(principal, session) do
      json(
        conn,
        Map.merge(workflows, %{
          schema_version: 1,
          principal: principal,
          catalog: Catalog.summary(catalog),
          results: result
        })
      )
    else
      error -> refuse(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    conn = private_response(conn)

    with {:ok, principal, session} <- authenticate(conn),
         :ok <- operations_access(principal),
         :ok <- document_id(id),
         {:ok, catalog} <- load_catalog(),
         {:ok, document} <- Catalog.document(catalog, id),
         workflows = workflow_index(catalog),
         :ok <- still_authorized(principal, session) do
      json(conn, %{
        schema_version: 1,
        principal: principal,
        source: Catalog.summary(catalog)["source"],
        read_only: true,
        document: document,
        workflows_available: workflows.workflows_available,
        workflows: Enum.filter(workflows.workflows, &(id in &1["source_document_ids"]))
      })
    else
      error -> refuse(conn, error)
    end
  end

  def workflow(conn, %{"id" => id}) do
    conn = private_response(conn)

    with {:ok, principal, session} <- authenticate(conn),
         :ok <- operations_access(principal),
         :ok <- document_id(id),
         {:ok, catalog} <- load_catalog(),
         {:ok, preview} <- Workflows.preview(catalog, id),
         :ok <- still_authorized(principal, session) do
      json(conn, %{
        schema_version: 1,
        principal: principal,
        source: Catalog.summary(catalog)["source"],
        read_only: true,
        workflow: preview
      })
    else
      error -> refuse(conn, error)
    end
  end

  def manifest(conn, params), do: artifact(conn, params, :manifest)
  def sop(conn, params), do: artifact(conn, params, :sop)

  defp artifact(conn, %{"id" => id}, kind) do
    conn = private_response(conn)

    with {:ok, principal, session} <- authenticate(conn),
         :ok <- operations_access(principal),
         :ok <- document_id(id),
         conn = fetch_query_params(conn),
         {:ok, expected_digest} <- expected_artifact_digest(conn.query_params),
         {:ok, catalog} <- load_catalog(),
         {:ok, artifact} <- Workflows.artifact(catalog, id, kind),
         true <- safe_artifact?(artifact) or {:error, :workflow_unavailable},
         :ok <- matches_artifact_digest(artifact.bytes, expected_digest),
         :ok <- still_authorized(principal, session) do
      conn
      |> put_resp_content_type(artifact.content_type)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{artifact.filename}"))
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, artifact.bytes)
    else
      error -> refuse(conn, error)
    end
  end

  defp safe_artifact?(%{bytes: bytes, filename: filename, content_type: type}) do
    is_binary(bytes) and byte_size(bytes) <= 1_048_576 and
      is_binary(filename) and Regex.match?(~r/\A[A-Za-z0-9._-]{1,128}\z/, filename) and
      type in ["application/yaml", "application/json", "text/yaml", "text/plain", "text/markdown"]
  end

  defp safe_artifact?(_), do: false

  # Browser links carry the digest shown in their preview. Direct API readers
  # may omit it to request the current artifact, but a supplied pin is strict.
  defp expected_artifact_digest(params) do
    case Map.fetch(params, "expected_sha256") do
      :error ->
        {:ok, nil}

      {:ok, digest} when is_binary(digest) and byte_size(digest) == 64 ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
          do: {:ok, digest},
          else: {:error, :invalid_query}

      _ ->
        {:error, :invalid_query}
    end
  end

  defp matches_artifact_digest(_bytes, nil), do: :ok

  defp matches_artifact_digest(bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, :stale_workflow_preview}
  end

  # Workflow validation is independent of reading the published corpus. A bad
  # preview remains unavailable without hiding otherwise valid source documents.
  defp workflow_index(catalog) do
    case Workflows.list(catalog) do
      {:ok, workflows} -> %{workflows: workflows, workflows_available: true}
      {:error, _} -> %{workflows: [], workflows_available: false}
    end
  end

  defp authenticate(conn) do
    case AuthController.principal(conn) do
      {:ok, principal, session} -> {:ok, principal, session}
      _ -> {:error, :unauthorized}
    end
  end

  defp operations_access(principal) do
    config = Application.get_env(:task_host, :operations, Operations.default_config())

    case Operations.snapshot(Log.gate(), principal, config) do
      {:ok, %{"workspaces" => [_ | _]}} -> :ok
      {:ok, _} -> {:error, :no_workspace_access}
      _ -> {:error, :operations_unavailable}
    end
  end

  # Loading/validating a snapshot must not release data after session or
  # workspace revocation. No caller-supplied principal or scope is accepted.
  defp still_authorized(principal, session) do
    with {:ok, %{principal: ^principal}} <- Identity.session(session) do
      operations_access(principal)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp load_catalog do
    case Catalog.load() do
      {:ok, catalog} -> {:ok, catalog}
      _ -> {:error, :knowledge_unavailable}
    end
  end

  defp search_options(params) do
    query = Map.get(params, "query", "")
    area = Map.get(params, "area", "")
    category = Map.get(params, "category", "")

    with true <- text?(query, 160) and text?(area, 256) and text?(category, 256),
         {:ok, offset} <- integer(Map.get(params, "offset", "0"), 0, 1000),
         {:ok, limit} <- integer(Map.get(params, "limit", "40"), 1, 100) do
      {:ok,
       [
         query: query,
         area: if(area == "", do: nil, else: area),
         category: if(category == "", do: nil, else: category),
         offset: offset,
         limit: limit
       ]}
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp text?(value, limit),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= limit

  defp integer(value, lower, upper) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= lower and number <= upper -> {:ok, number}
      _ -> :error
    end
  end

  defp integer(_, _, _), do: :error

  # IDs index a validated manifest; they are never concatenated into a path.
  defp document_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9._-]{1,128}\z/, value),
      do: :ok,
      else: {:error, :not_found}
  end

  defp document_id(_), do: {:error, :not_found}

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp refuse(conn, {:error, reason}) do
    {status, error} =
      case reason do
        :unauthorized -> {401, "unauthorized"}
        :no_workspace_access -> {403, "workspace_access_required"}
        :not_found -> {404, "not_found"}
        :invalid_query -> {400, "invalid_query"}
        :stale_workflow_preview -> {409, "stale_workflow_preview"}
        :operations_unavailable -> {503, "operations_unavailable"}
        :workflow_unavailable -> {503, "workflow_unavailable"}
        _ -> {503, "knowledge_unavailable"}
      end

    conn |> put_status(status) |> json(%{error: error})
  end
end
