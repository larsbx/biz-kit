defmodule FederationService.Router do
  @moduledoc "Public actor, metadata, read-only combined market and authenticated inbox routes."
  import Plug.Conn
  alias FederationService.{Signature, Store, Inbox, WebFinger}
  def init(config), do: config

  def call(conn, config) do
    host = URI.parse(config.actor).host

    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      )

    with true <- get_req_header(conn, "host") == [host],
         true <- valid_query?(conn),
         :ok <- Store.call(config.store, {:rate, :http, 600, System.system_time(:second)}) do
      route(conn, config)
    else
      _ -> send_resp(conn, 400, "Request refused")
    end
  end

  defp valid_query?(%{query_string: ""}), do: true

  defp valid_query?(%{method: "GET", request_path: "/.well-known/webfinger", query_string: q})
       when byte_size(q) <= 512 do
    case Enum.to_list(URI.query_decoder(q)) do
      [{"resource", resource}] -> byte_size(resource) <= 256 and String.valid?(resource)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_query?(%{method: "GET", request_path: path, query_string: q})
       when path in ["/market", "/market.json"] and byte_size(q) <= 512 do
    case URI.decode_query(q) do
      %{"q" => term} = params ->
        map_size(params) == 1 and byte_size(term) <= 160 and String.valid?(term)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_query?(_), do: false
  defp query(conn), do: URI.decode_query(conn.query_string)["q"] || ""

  defp route(%{method: "GET", request_path: path} = conn, config) do
    actor_path = URI.parse(config.actor).path

    cond do
      path == "/.well-known/webfinger" ->
        case WebFinger.document(config, URI.decode_query(conn.query_string)["resource"]) do
          {:ok, document} -> json(conn, 200, document, "application/jrd+json")
          {:error, _} -> send_resp(conn, 404, "")
        end

      path == actor_path and config.private_key == nil ->
        send_resp(conn, 404, "")

      path == actor_path ->
        json(
          conn,
          200,
          Signature.actor(config.actor, config.private_key, config.handle),
          "application/activity+json"
        )

      path == actor_path <> "/outbox" ->
        rows = Store.call(config.store, :snapshot).publications |> Map.values()

        json(
          conn,
          200,
          %{
            "@context" => "https://www.w3.org/ns/activitystreams",
            "id" => config.actor <> "/outbox",
            "type" => "OrderedCollection",
            "totalItems" => length(rows),
            "first" => config.actor <> "/outbox/page/0"
          },
          "application/activity+json"
        )

      String.starts_with?(path, actor_path <> "/outbox/page/") ->
        page(conn, config, path)

      path == "/market.json" ->
        json(conn, 200, %{"listings" => FederationService.search(config, query(conn))})

      path == "/market" ->
        send_resp(put_resp_content_type(conn, "text/html"), 200, html(config, query(conn)))

      true ->
        listing(conn, config, path)
    end
  end

  defp route(%{method: "POST", request_path: path} = conn, config) do
    if path == URI.parse(config.actor).path <> "/inbox" do
      with {:ok, body, conn} <-
             read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 2000),
           {:ok, _} <- Inbox.receive_request(config, path, conn.req_headers, body) do
        send_resp(conn, 202, "")
      else
        {:more, _, conn} -> send_resp(conn, 413, "Body too large")
        _ -> send_resp(conn, 401, "Inbox refused")
      end
    else
      send_resp(conn, 404, "")
    end
  end

  defp route(conn, _), do: send_resp(conn, 405, "")

  defp listing(conn, config, path) do
    url = "https://" <> URI.parse(config.actor).host <> path

    id =
      if String.ends_with?(url, ".json"), do: String.replace_suffix(url, ".json", ""), else: url

    case Store.call(config.store, :snapshot).local[id] do
      nil ->
        send_resp(conn, 404, "")

      %{withdrawn: true} ->
        json(conn, 410, %{"id" => id, "type" => "Tombstone"}, "application/activity+json")

      %{metadata: m} ->
        json(conn, 200, m)
    end
  end

  defp page(conn, config, path) do
    prefix = URI.parse(config.actor).path <> "/outbox/page/"

    case Integer.parse(String.replace_prefix(path, prefix, "")) do
      {n, ""} when n >= 0 and n < 500 ->
        rows =
          Store.call(config.store, :snapshot).publications
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        doc = %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => "https://" <> URI.parse(config.actor).host <> path,
          "type" => "OrderedCollectionPage",
          "partOf" => config.actor <> "/outbox",
          "orderedItems" => Enum.slice(rows, n * 20, 20)
        }

        doc =
          if length(rows) > (n + 1) * 20,
            do: Map.put(doc, "next", config.actor <> "/outbox/page/#{n + 1}"),
            else: doc

        json(conn, 200, doc, "application/activity+json")

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, status, value, type \\ "application/json"),
    do: send_resp(put_resp_content_type(conn, type), status, Jason.encode!(value))

  defp html(config, query) do
    rows =
      for r <- FederationService.search(config, query) do
        m = r.metadata

        price =
          case m["price"] do
            %{"mode" => "quote"} -> "Quote required"
            p -> "#{p["minor_units"]} minor units #{p["currency"]}"
          end

        "<article><h2>#{escape(m["name"])}</h2><p>#{escape(m["summary"])}</p><p>#{escape(price)}</p>" <>
          "<p>Source: <a rel=\"noreferrer noopener\" href=\"#{escape(r.listing_id)}\">#{escape(r.source)}</a> · " <>
          "#{if r.local, do: "Local", else: "Remote"} · #{if r.stale, do: "Stale", else: "Recently verified"} · revision #{m["revision"]}</p>" <>
          "<p>Verified at #{r.verified_at} (Unix seconds). Advertisement only; contact the source to confirm terms.</p></article>"
      end

    "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Combined marketplace</title><h1>Combined marketplace</h1><p>Public listings from this installation and configured peers. No orders or payments are executed here.</p><form action=\"/market\" method=\"get\"><label>Search <input name=\"q\" maxlength=\"160\"></label><button>Search</button></form>" <>
      Enum.join(rows, "\n") <> "</html>"
  end

  defp escape(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&#39;")
end
