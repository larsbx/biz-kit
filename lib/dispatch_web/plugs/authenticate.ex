defmodule DispatchWeb.Plugs.Authenticate do
  @moduledoc """
  Turns a bearer token into verified claims.

  Authentication only. Section 23.2 separates it sharply from authorization:
  this plug establishes *who* is calling and nothing about what they may do.
  `ResolveActor` does the second half, and `Ash` policies the third.
  """

  @behaviour Plug

  import Plug.Conn

  alias Dispatch.Identity.Tokens.Verifier

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Verifier.verify(token) do
      assign(conn, :oidc_claims, claims)
    else
      {:error, _reason} -> deny(conn)
      _missing_header -> deny(conn)
    end
  end

  # Section 24.7's shape: a stable, non-sensitive reason code. The body does not
  # say whether the token was absent, expired or wrongly signed — that
  # distinction helps an attacker more than a client.
  defp deny(conn) do
    DispatchWeb.Problem.send(conn, 401, "UNAUTHENTICATED", "A valid bearer token is required.")
  end
end
