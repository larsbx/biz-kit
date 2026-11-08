defmodule ProcurementHost.Router do
  use Plug.Router
  alias CoopSubstrate.Procurement
  alias ProcurementHost.{Auth, HTML}
  plug :match
  plug :dispatch

  get "/healthz" do
    # Liveness only; release acceptance also exercises ledger writes/replay.
    send_resp(conn, 200, "procurement-host\n")
  end
  get "/login" do
    page(conn, "Coordinator sign-in", HTML.login())
  end
  post "/login" do
    case Auth.login(conn, conn.body_params["token"]) do
      {:ok, conn} -> redirect(conn, "/requests")
      _ -> page(conn, "Sign-in refused", "<p>Invalid or inactive coordinator credential.</p>" <> HTML.login(), 401)
    end
  end
  post "/logout" do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> configure_session(drop: true) |> redirect("/login")
  end
  get "/" do
    redirect(conn, "/requests")
  end
  get "/requests" do
    protected(conn, fn conn, _context, snapshot ->
      page(conn, "Requests", HTML.requests(snapshot))
    end)
  end
  get "/orders" do
    protected(conn, fn conn, _context, snapshot ->
      page(conn, "Quotes and orders", HTML.orders(snapshot))
    end)
  end
  get "/operations" do
    protected(conn, fn conn, _context, snapshot ->
      page(conn, "Operations and evidence", HTML.operations(snapshot))
    end)
  end
  get "/requests/:id" do
    protected(conn, fn conn, _context, snapshot ->
      case Enum.find(snapshot.requests, &(elem(&1.scope, 2) == id)) do
        nil -> page(conn, "Not found", "<p>No request in this cooperative.</p>", 404)
        row -> page(conn, "Request " <> id, HTML.detail(row, snapshot.businesses))
      end
    end)
  end
  post "/requests/:id/:action" do
    protected(conn, fn conn, context, _snapshot ->
      with {:ok, attrs} <- HTML.attributes(action, conn.body_params),
           {version, ""} <- Integer.parse(conn.body_params["expected_version"] || ""),
           command = %{"id" => conn.body_params["command_id"], "expected_version" => version,
             "action" => action, "attrs" => attrs},
           {:ok, _} <- Procurement.submit(context, id, command, Auth.server()) do
        redirect(conn, "/requests/" <> URI.encode(id, &URI.char_unreserved?/1))
      else
        _ -> page(conn, "Command not accepted",
          "<p>No success receipt was obtained. The command may be invalid, stale, or no longer authorized. " <>
          "Reload the request before retrying; a lost response may already have committed.</p>", 409)
      end
    end)
  end
  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp protected(conn, fun) do
    with {:ok, context} <- Auth.context(conn),
         {:ok, snapshot} <- Procurement.snapshot(context, Auth.server()) do
      fun.(conn, context, snapshot)
    else
      _ -> conn |> configure_session(drop: true) |> redirect("/login")
    end
  end
  defp page(conn, title, body, status \\ 200),
    do: conn |> put_resp_content_type("text/html") |> send_resp(status, HTML.page(title, body))
  defp redirect(conn, path), do: conn |> put_resp_header("location", path) |> send_resp(303, "")
end

defmodule ProcurementHost.Web do
  @moduledoc "Server-rendered operator console. No public ledger read, seed, or authority fields in forms."
  use Plug.Builder
  plug :secret
  plug Plug.Parsers, parsers: [:urlencoded], pass: [], length: 16_384
  plug Plug.Session, store: :cookie, key: "_procurement_pilot",
    signing_salt: "procurement-sign-v1", encryption_salt: "procurement-encrypt-v1",
    secure: true, http_only: true, same_site: "Strict", max_age: 14_400
  plug :fetch_session
  plug Plug.CSRFProtection
  plug :headers
  plug ProcurementHost.Router

  def secret(conn, _), do: %{conn | secret_key_base: ProcurementHost.Auth.settings().secret_key_base}
  def headers(conn, _) do
    conn |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
  end
end

