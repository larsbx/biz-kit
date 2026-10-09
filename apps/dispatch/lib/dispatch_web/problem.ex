defmodule DispatchWeb.Problem do
  @moduledoc """
  RFC 9457 Problem Details for deliberate rejections (Section 19.2).

  `DispatchWeb.ErrorJSON` renders the same shape for *unhandled* errors, where
  the only thing known is a status code. This module is the other half: a
  rejection the server chose, carrying the stable, non-sensitive reason code
  Sections 24.7 and 32 require.

  The code is the contract. Clients branch on `code`; `detail` is prose for a
  human reading a log and may be reworded without breaking anyone. Neither ever
  carries internal state — "which of the several reasons your token failed" is
  more useful to an attacker than to a client.
  """

  import Plug.Conn

  @type code :: String.t()

  @base "https://dispatch.invalid/problems/"

  @doc """
  Renders the problem body for a rejection.

  Split from `send/4` so controllers that must embed a problem in a larger
  document (Section 24.2's `207` item results) build the same shape.
  """
  @spec body(Plug.Conn.t(), pos_integer(), code(), String.t()) :: map()
  def body(conn, status, code, detail) do
    %{
      type: @base <> slug(code),
      title: Plug.Conn.Status.reason_phrase(status),
      status: status,
      detail: detail,
      instance: conn.request_path,
      code: code,
      correlation_id: correlation_id(conn)
    }
  end

  @doc """
  Sends the problem and halts the connection.

  Halting is not optional: every caller is a plug or a controller rejecting the
  request, and a pipeline that continued past a `401` would run the very code
  the rejection exists to prevent.
  """
  @spec send(Plug.Conn.t(), pos_integer(), code(), String.t()) :: Plug.Conn.t()
  def send(conn, status, code, detail) do
    conn
    |> put_resp_content_type("application/problem+json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode_to_iodata!(body(conn, status, code, detail)))
    |> halt()
  end

  # `UNAUTHENTICATED` and `unauthenticated` are the same problem kind, so the
  # type URI is the code in one canonical spelling rather than a second
  # vocabulary to keep in step with the first.
  defp slug(code), do: code |> String.downcase() |> String.replace("_", "-")

  # Plug.RequestId assigns this on every request (see the endpoint). A response
  # without one would be untraceable, which Section 19.2 does not allow, so the
  # absent case is explicit rather than an empty string.
  defp correlation_id(%Plug.Conn{assigns: %{correlation_id: id}}) when is_binary(id), do: id
  defp correlation_id(_conn), do: "unassigned"
end
