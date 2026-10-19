defmodule SpruceGoose.Web.ArtifactController do
  @moduledoc """
  A person's device stores an artifact it will record custody of
  (docs/architecture/2026-10-19-uploads.md). Transport only:
  `CoopSubstrate.ArtifactCustody.store/4` decides.

      POST /api/v1/chapters/:c/tenants/:t/projects/:p/artifacts   (session)
           content-type: application/octet-stream
           x-content-sha256: <hex SHA-256 the device computed>
           <the bytes>
           → 201 {digest, size}

      POST …/artifacts?evidence_for=<task_id>     (evidence for a task in progress)

      GET  /api/v1/chapters/:c/tenants/:t/projects/:p/tasks/:task_id/evidence   (session)
           → {submission_event_id, principal_id, evidence: {criterion: {digest, custody_receipt_id}}}
      GET  /api/v1/chapters/:c/tenants/:t/projects/:p/receipts/:receipt_id     (session)
           → the receipt's bytes, as an attachment

  Storing gives no custody: the device then signs `ArtifactCustodyRecordedV1`
  for the digest through `/commands`, and the ledger admits it once the
  bytes are there. Only a digest a task in the project names (its SOP or a
  required input), or evidence for a task in progress within the person's
  quota (docs/architecture/2026-10-19-execution.md), is accepted, and that
  is checked before any byte is read. At most `ArtifactCustody.limit/0`
  bytes are read; a larger body is refused without being buffered whole.

  Evidence is read by the project's operators and reviewers, for review; it
  is served as a download, never rendered in the page's origin.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn
  import SpruceGoose.Web.Requests

  alias CoopSubstrate.ArtifactCustody
  alias SpruceGoose.Web.AuthController

  def create(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    task = query(conn, "evidence_for")

    with {:ok, principal, _session} <- AuthController.principal(conn),
         true <- task == nil or is_binary(task),
         ["application/octet-stream" <> _] <- get_req_header(conn, "content-type"),
         [hex] <- get_req_header(conn, "x-content-sha256"),
         {:ok, <<_::256>> = claimed} <- Base.decode16(hex, case: :mixed),
         :ok <- ArtifactCustody.may_store(principal, {c, t, p}, claimed, task),
         {:ok, bytes, conn} <- read_all(conn, ArtifactCustody.limit()),
         {:ok, digest} <- ArtifactCustody.store(principal, {c, t, p}, bytes, claimed, task) do
      conn
      |> put_status(201)
      |> json(%{digest: Base.encode16(digest, case: :lower), size: byte_size(bytes)})
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  def evidence(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p, "task_id" => id}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         {:ok, e} <- ArtifactCustody.evidence(principal, {c, t, p}, id) do
      json(conn, %{
        submission_event_id: e.submission_event_id,
        principal_id: e.principal_id,
        evidence:
          Map.new(e.evidence, fn {criterion, item} ->
            {criterion, %{item | digest: Base.encode16(item.digest, case: :lower)}}
          end)
      })
    else
      error -> refuse(conn, error)
    end
  end

  # Always a download of opaque bytes: nothing a person uploaded runs here.
  def show(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p, "receipt_id" => id}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         {:ok, bytes} <- ArtifactCustody.read(principal, {c, t, p}, id) do
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{download_name(id)}"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, bytes)
    else
      {:error, reason}
      when reason in [:unknown_custody_receipt, :custody_scope_mismatch, :not_found] ->
        refuse(conn, {:error, :unknown_receipt})

      error ->
        refuse(conn, error)
    end
  end

  # Receipt IDs are ULIDs; anything else is not echoed into a header.
  defp download_name(id),
    do: if(id =~ ~r/\A[0-9A-Za-z]{1,64}\z/, do: id, else: "artifact")

  # The whole body, if it is within `limit`.
  defp read_all(conn, limit, acc \\ []) do
    case read_body(conn, length: 1_000_000) do
      {:ok, chunk, conn} -> within(conn, [acc | chunk], limit, :done)
      {:more, chunk, conn} -> within(conn, [acc | chunk], limit, :more)
      {:error, reason} -> {:error, reason}
    end
  end

  defp within(conn, acc, limit, state) do
    cond do
      IO.iodata_length(acc) > limit -> {:error, :too_large}
      state == :done -> {:ok, IO.iodata_to_binary(acc), conn}
      true -> read_all(conn, limit, acc)
    end
  end
end
