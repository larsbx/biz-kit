defmodule DispatchWeb.Plugs.DiagnosticAuth do
  @moduledoc """
  Guards `/health/dependencies`, which Section 32 requires to be authenticated.

  The check is a constant-time comparison against a runtime-configured token.
  Section 31 requires startup to fail closed when a required production secret
  is absent, so an unset token denies every request rather than allowing all.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, expected} <- configured_token(),
         {:ok, presented} <- bearer_token(conn),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      _ -> deny(conn)
    end
  end

  defp configured_token do
    case Application.get_env(:dispatch, :diagnostics_token) do
      token when is_binary(token) and byte_size(token) >= 32 -> {:ok, token}
      _ -> :error
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _ -> :error
    end
  end

  # RFC 9457 Problem Details (Section 19.2). The body carries no hint about
  # which precondition failed.
  defp deny(conn) do
    body =
      Jason.encode!(%{
        type: "https://dispatch.invalid/problems/unauthorized",
        title: "Unauthorized",
        status: 401,
        detail: "Diagnostic access requires a valid bearer token.",
        instance: conn.request_path,
        code: "DIAGNOSTICS_UNAUTHORIZED",
        correlation_id: conn.assigns[:correlation_id] || "unassigned"
      })

    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(401, body)
    |> halt()
  end
end
