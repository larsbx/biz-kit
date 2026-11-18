defmodule DispatchWeb.FleetMapController do
  @moduledoc """
  A small, same-origin globe over the authorized location snapshot.

  The document carries no observations. The JSON/SSE endpoints authorize each
  read independently; opening this page cannot grant location access.
  """

  use Phoenix.Controller, formats: [:html]

  alias Dispatch.Operations.LocationSnapshot

  # Cesium positions its canvas/widgets with style attributes and creates local
  # workers. CreditDisplay also injects one fixed stylesheet, whose exact
  # Cesium 1.138.0 bytes are covered by this hash and the real browser test.
  # These exceptions apply only to this page. All resources stay same-origin.
  @csp "default-src 'self'; script-src 'self'; " <>
         "style-src 'self' 'sha256-W9isZ7K65dw04+sGbSAyiFtvwt94eXJiQXtiU8lmkRg='; " <>
         "style-src-attr 'unsafe-inline'; img-src 'self' data: blob:; " <>
         "connect-src 'self'; font-src 'self'; worker-src 'self' blob:; " <>
         "object-src 'none'; frame-src 'none'; frame-ancestors 'none'; " <>
         "base-uri 'none'; form-action 'self'"

  @doc "The map page's narrowly scoped browser policy."
  def content_security_policy, do: @csp

  def index(conn, _params) do
    case LocationSnapshot.authorize(conn.assigns.actor) do
      {:ok, actor} ->
        conn
        |> put_resp_header("content-security-policy", @csp)
        |> render(:index, actor: actor, scope_key: LocationSnapshot.scope_key(actor))

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end
end
