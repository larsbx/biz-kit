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

  Storing gives no custody: the device then signs `ArtifactCustodyRecordedV1`
  for the digest through `/commands`, and the ledger admits it once the
  bytes are there. At most `ArtifactCustody.limit/0` bytes are read; a larger
  body is refused without being buffered whole.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn
  import SpruceGoose.Web.Requests

  alias CoopSubstrate.ArtifactCustody
  alias SpruceGoose.Web.AuthController

  def create(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    with {:ok, principal, _session} <- AuthController.principal(conn),
         :ok <- ArtifactCustody.may_store(principal, {c, t, p}),
         ["application/octet-stream" <> _] <- get_req_header(conn, "content-type"),
         [hex] <- get_req_header(conn, "x-content-sha256"),
         {:ok, claimed} <- Base.decode16(hex, case: :mixed),
         {:ok, bytes, conn} <- read_all(conn, ArtifactCustody.limit()),
         {:ok, digest} <- ArtifactCustody.store(principal, {c, t, p}, bytes, claimed) do
      conn
      |> put_status(201)
      |> json(%{digest: Base.encode16(digest, case: :lower), size: byte_size(bytes)})
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

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
