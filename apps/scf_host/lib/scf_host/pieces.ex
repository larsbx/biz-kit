defmodule ScfHost.Pieces do
  @moduledoc """
  Pièces justificatives, kept on this machine (local-first). Bytes go to the
  substrate's content-addressed artifact store (`COOP_ARTIFACT_DIR`), only
  their SHA-256 enters a signed posting, and the Log refuses a posting whose
  pièce is not held here. Reads are limited to pièces this book cites.

  The 8 MiB bound is the platform's custody limit.
  """
  alias CoopSubstrate.Harness.Artifacts

  @limit 8 * 1024 * 1024

  def limit, do: @limit

  @doc "Store bytes whose SHA-256 the client claims (hex); idempotent."
  def store(bytes, claimed_hex) when is_binary(bytes) and is_binary(claimed_hex) do
    with {:ok, claimed} <- Base.decode16(claimed_hex, case: :mixed),
         true <- byte_size(claimed) == 32 || :error do
      cond do
        byte_size(bytes) > @limit -> {:error, :too_large}
        :crypto.hash(:sha256, bytes) != claimed -> {:error, :digest_mismatch}
        true -> put(bytes)
      end
    else
      _ -> {:error, :invalid_digest}
    end
  end

  @doc "Store a form upload; replaces it in params by its hex digest."
  def from_upload(%{"document" => %Plug.Upload{path: path}} = params) do
    with {:ok, %{size: size}} when size <= @limit <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, hex} <- put(bytes) do
      {:ok, params |> Map.delete("document") |> Map.put("document_sha256", hex)}
    else
      {:ok, %{size: _}} -> {:error, :document_too_large}
      _ -> {:error, :invalid_document}
    end
  end

  def from_upload(params), do: {:ok, params}

  @doc "The bytes of a pièce cited by a posting of this book."
  def fetch(book, hex) do
    with {:ok, digest} <- Base.decode16(hex, case: :lower),
         %{"id" => id} <- cited(book, digest),
         {:ok, bytes} <- Artifacts.get_bounded(digest) do
      {:ok, id, bytes}
    else
      _ -> :error
    end
  end

  @doc "Serve a pièce as a download, never rendered inline."
  def respond(conn, id, bytes) do
    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream", nil)
    |> Plug.Conn.put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{filename(id)}")
    )
    |> Plug.Conn.send_resp(200, bytes)
  end

  defp filename(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  defp cited(book, digest),
    do:
      Enum.find_value(book.postings, fn {_, p} -> p.document["sha256"] == digest && p.document end)

  defp put(bytes) do
    with {:ok, digest} <- Artifacts.put(bytes), do: {:ok, Base.encode16(digest, case: :lower)}
  end
end
