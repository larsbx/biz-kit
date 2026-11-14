defmodule TaskHost.Web.InfrastructureReviewController do
  @moduledoc "Authenticated review navigation from an authorized Operations workspace."

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn
  import Plug.HTML, only: [html_escape: 1]

  alias BizKit.Identity
  alias CoopSubstrate.Log
  alias TaskHost.{InfrastructureReview, Operations}
  alias TaskHost.Web.AuthController

  def show(conn, %{"workspace_id" => workspace_id}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
      )

    config = Application.get_env(:task_host, :operations, Operations.default_config())

    with {:ok, principal, session} <- AuthController.principal(conn),
         {:ok, review} <-
           Operations.infrastructure_review(Log.gate(), principal, config, workspace_id),
         {:ok, ship_url} <- InfrastructureReview.ship_link(review, conn.host),
         keel = InfrastructureReview.keel(Application.get_env(:task_host, :keel_review_manifest)),
         {:ok, %{principal: ^principal}} <- Identity.session(session) do
      html(conn, page(review["record"], ship_url, keel))
    else
      {:error, :not_found} ->
        send_resp(conn, 404, "Review unavailable")

      {:error, :invalid_ship_review} ->
        send_resp(conn, 503, "Ship review unavailable")

      _unauthenticated ->
        send_resp(conn, 401, "Sign in to Biz-kit to review infrastructure evidence")
    end
  end

  defp page(%{"repository" => repository, "report" => report}, ship_url, keel) do
    """
    <!doctype html>
    <html lang="en">
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Infrastructure review · Biz-kit</title>
      <nav><a href="/operations">Operations</a></nav>
      <main>
        <h1>Infrastructure review</h1>
        <h2>Ship Graft source review</h2>
        <dl>
          <dt>Repository</dt><dd>#{html_escape(repository)}</dd>
          <dt>Commit</dt><dd><code>#{html_escape(report["commit"])}</code></dd>
          <dt>Tree</dt><dd><code>#{html_escape(report["tree"])}</code></dd>
          <dt>Bundle SHA-256</dt><dd><code>#{html_escape(report["bundle_sha256"])}</code></dd>
        </dl>
        <p>Ship checks your review permissions and the catalog binding when you open the link.</p>
        <a href="#{html_escape(ship_url)}" rel="noreferrer">Open exact fixture review in Ship</a>
        <p>If Ship is unavailable, retry this link when the service returns. If Ship reports changed evidence, ask the workspace operator to update the binding.</p>
        #{keel_section(keel)}
        <h2>Evidence and authority</h2>
        <dl>
          <dt>Source verification</dt><dd>Ship verifies fixture integrity on arrival. Current stage, upstream provenance and runner trust are unverified here.</dd>
          <dt>Mathematical proof acceptance</dt><dd>Consult the existing proof authority for the exact revision.</dd>
          <dt>CI authority</dt><dd>Consult canonical CI for the exact revision.</dd>
          <dt>Deployment approval</dt><dd>No approval is established by this review.</dd>
          <dt>Deployment execution</dt><dd>No execution is performed by this review.</dd>
        </dl>
      </main>
    </html>
    """
  end

  defp keel_section({:ok, %{repository: repository, revision: revision, roles: roles}}) do
    declarations =
      Enum.map_join(roles, "\n", fn {role, responsibility} ->
        "<dt>#{html_escape(role)}</dt><dd>#{html_escape(responsibility)}</dd>"
      end)

    """
    <h2>Keel manifest</h2>
    <p>#{html_escape(repository)} · <code>#{html_escape(revision)}</code></p>
    <dl>#{declarations}</dl>
    """
  end

  defp keel_section({:error, _reason}) do
    "<h2>Keel manifest</h2><p>The pinned Keel manifest is unavailable or incompatible.</p>"
  end
end
