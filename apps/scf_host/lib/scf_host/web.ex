defmodule ScfHost.Router do
  @moduledoc false
  use Plug.Router
  alias CoopSubstrate.{Scf, ULID}
  alias ScfHost.{Auth, Commands, HTML, Reports}

  plug(:match)
  plug(:dispatch)

  get("/healthz", do: send_resp(conn, 200, "scf-host\n"))

  get("/login", do: page(conn, "Connexion", HTML.login(), "—"))

  post "/login" do
    case Auth.login(conn, conn.body_params["token"]) do
      {:ok, conn} -> redirect(conn, "/journal")
      _ -> page(conn, "Connexion refusée", HTML.login(:invalid_credentials), "—", 401)
    end
  end

  post "/logout" do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> configure_session(drop: true) |> redirect("/login")
  end

  get("/", do: redirect(conn, "/journal"))

  get "/journal" do
    protected(conn, fn conn, _ctx, book ->
      page(conn, "Journal", HTML.journal(Reports.journal(book), ULID.generate()), book.entity_id)
    end)
  end

  get "/ecriture" do
    protected(conn, fn conn, _ctx, book ->
      page(conn, "Nouvelle écriture", HTML.entry_form(ULID.generate()), book.entity_id)
    end)
  end

  post "/ecriture" do
    protected(conn, fn conn, ctx, book ->
      case submit(ctx, book, Map.put(conn.body_params, "kind", "entry")) do
        :ok ->
          redirect(conn, "/journal")

        {:error, reason} ->
          body =
            HTML.error(reason) <>
              HTML.entry_form(conn.body_params["command_id"] || ULID.generate(), conn.body_params)

          page(conn, "Nouvelle écriture", body, book.entity_id, 422)
      end
    end)
  end

  post "/journal/:seq/contrepasser" do
    command(
      conn,
      Map.merge(conn.body_params, %{"kind" => "reversal", "target" => seq}),
      "/journal"
    )
  end

  get "/balance" do
    protected(conn, fn conn, _ctx, book ->
      page(
        conn,
        "Balance générale",
        HTML.balance(Reports.statements(book, conn.query_params)),
        book.entity_id
      )
    end)
  end

  get "/etats" do
    protected(conn, fn conn, _ctx, book ->
      body =
        HTML.statements(
          Reports.statements(book, conn.query_params),
          ULID.generate(),
          book.open_year
        )

      page(conn, "États financiers", body, book.entity_id)
    end)
  end

  post("/cloture", do: command(conn, Map.put(conn.body_params, "kind", "close"), "/etats"))

  get "/tva" do
    protected(conn, fn conn, _ctx, book ->
      params =
        Map.put_new(conn.query_params, "mois", Calendar.strftime(Date.utc_today(), "%Y-%m"))

      page(conn, "TVA (G50)", HTML.tva(Reports.statements(book, params)), book.entity_id)
    end)
  end

  match(_, do: send_resp(conn, 404, "Introuvable"))

  defp command(conn, params, back) do
    protected(conn, fn conn, ctx, book ->
      case submit(ctx, book, params) do
        :ok ->
          redirect(conn, back)

        {:error, reason} ->
          page(
            conn,
            "Opération refusée",
            HTML.error(reason) <> "<p><a href=\"#{back}\">Retour</a></p>",
            book.entity_id,
            422
          )
      end
    end)
  end

  @doc false
  # Shared by the console and the API: parse, sign, append.
  def submit(ctx, book, params) do
    with {:ok, type, id, attrs} <- Commands.build(params, book),
         {:ok, _} <- Scf.post(ctx, type, id, attrs, Auth.server()) do
      :ok
    else
      {:error, {:reject, _, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  defp protected(conn, fun) do
    with {:ok, ctx} <- Auth.session_context(conn),
         {:ok, book} <- Scf.book(ctx, Auth.server()) do
      fun.(conn, ctx, book)
    else
      _ -> conn |> configure_session(drop: true) |> redirect("/login")
    end
  end

  defp page(conn, title, body, entity, status \\ 200),
    do:
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(status, HTML.page(title, body, entity))

  defp redirect(conn, path), do: conn |> put_resp_header("location", path) |> send_resp(303, "")
end

defmodule ScfHost.API do
  @moduledoc """
  JSON API under `/api/v1`, authenticated by `Authorization: Bearer <token>`
  (no cookies, so no CSRF). Same commands and views as the console.

      GET  /api/v1/journal
      GET  /api/v1/statements?from=YYYY-MM-DD&to=YYYY-MM-DD   (or mois=YYYY-MM)
      POST /api/v1/commands   {"kind": "entry"|"reversal"|"close", "command_id": ..., ...}
  """
  import Plug.Conn
  alias CoopSubstrate.Scf
  alias ScfHost.{Auth, Reports, Router}

  def call(%{path_info: ["api", "v1" | path]} = conn) do
    with {:ok, ctx} <- Auth.api_context(conn),
         {:ok, book} <- Scf.book(ctx, Auth.server()) do
      route(conn.method, path, conn, ctx, book)
    else
      {:error, :authentication_required} -> json(conn, 401, %{error: "authentication_required"})
      {:error, reason} -> json(conn, 403, %{error: inspect(reason)})
    end
    |> halt()
  end

  def call(conn), do: conn

  defp route("GET", ["journal"], conn, _, book),
    do:
      json(conn, 200, %{
        entity_id: book.entity_id,
        open_year: book.open_year,
        journal: Reports.journal(book)
      })

  defp route("GET", ["statements"], conn, _, book),
    do: json(conn, 200, Reports.statements(book, conn.query_params))

  defp route("POST", ["commands"], conn, ctx, book) do
    case Router.submit(ctx, book, conn.body_params) do
      :ok ->
        json(conn, 201, %{status: "admitted"})

      {:error, {:invalid_entry, errors}} ->
        json(conn, 422, %{error: "invalid_entry", details: Enum.map(errors, &inspect/1)})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  defp route(_, _, conn, _, _), do: json(conn, 404, %{error: "not_found"})

  defp json(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(Reports.to_json(body)))
end

defmodule ScfHost.Web do
  @moduledoc "Console (session + CSRF) and API (bearer) in one endpoint, behind strict headers."
  use Plug.Builder

  plug(:secret)
  plug(:headers)

  plug(Plug.Parsers,
    parsers: [:urlencoded, {:multipart, length: 10_000_000}, :json],
    pass: [],
    length: 262_144,
    json_decoder: Jason
  )

  plug(:api)

  plug(Plug.Session,
    store: :cookie,
    key: "_scf_console",
    signing_salt: "scf-sign-v1",
    encryption_salt: "scf-encrypt-v1",
    secure: true,
    http_only: true,
    same_site: "Strict",
    max_age: 14_400
  )

  plug(:fetch_session)
  plug(:fetch_query_params)
  plug(Plug.CSRFProtection)
  plug(ScfHost.Router)

  def api(conn, _), do: ScfHost.API.call(fetch_query_params(conn))
  def secret(conn, _), do: %{conn | secret_key_base: ScfHost.Auth.settings().secret_key_base}

  def headers(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
    )
  end
end
