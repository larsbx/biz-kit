defmodule SpruceGoose.Web.AppController do
  @moduledoc """
  The minimal web view for the first workflow (docs/architecture/2026-10-18-decide.md):
  a project's tasks and pending suggestions from the feed, with accept and
  decline signed by the browser's device key. Static files from
  `priv/static/app`; only the files listed here are served.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  @files %{
    "index.html" => "text/html",
    "app.js" => "text/javascript",
    "cbor.js" => "text/javascript",
    "device.js" => "text/javascript",
    "view.js" => "text/javascript"
  }

  def index(conn, _params), do: serve(conn, "index.html")

  def file(conn, %{"file" => file}) when is_map_key(@files, file), do: serve(conn, file)
  def file(conn, _params), do: send_resp(conn, 404, "")

  defp serve(conn, file) do
    conn
    |> put_resp_content_type(@files[file])
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
    )
    |> send_file(200, Application.app_dir(:spruce_goose, Path.join("priv/static/app", file)))
  end
end
