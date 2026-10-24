defmodule Eatsbot.HttpSecurityTest do
  use ExUnit.Case, async: false

  defmodule Provider do
    @behaviour Plug

    @impl true
    def init(handler), do: handler

    @impl true
    def call(conn, handler), do: handler.(conn)
  end

  setup do
    previous =
      Map.new([:req_impl, :geocoding_endpoint, :geocoding_token], fn key ->
        {key, Application.fetch_env(:eatsbot, key)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:eatsbot, key, value)
        {key, :error} -> Application.delete_env(:eatsbot, key)
      end)
    end)

    Application.put_env(:eatsbot, :req_impl, Req)
    Application.put_env(:eatsbot, :geocoding_token, "test-token")

    if :ets.whereis(:geocoding_cache) == :undefined do
      Eatsbot.GeocodingStore.init()
    else
      :ets.delete_all_objects(:geocoding_cache)
    end

    :ok
  end

  test "geocoding decodes bounded JSON and caches a successful response" do
    serve(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "[{\"lat\":\"1\"}]")
    end)

    assert Eatsbot.Geocoding.query("bounded") == %{"lat" => "1"}
    assert Eatsbot.GeocodingStore.get_cached("bounded") == {:ok, %{"lat" => "1"}}
  end

  test "geocoding stops an oversized streamed response and does not cache it" do
    serve(fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce_while(1..40, conn, fn _, conn ->
        case Plug.Conn.chunk(conn, String.duplicate(" ", 8192)) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end)

    assert_raise Eatsbot.Geocoding.ResponseTooLargeError, fn ->
      Eatsbot.Geocoding.query("oversized")
    end

    assert Eatsbot.GeocodingStore.get_cached("oversized") == :error
  end

  test "geocoding never inflates an unsolicited compressed response" do
    compressed = :zlib.gzip(String.duplicate(" ", 2_000_000))

    serve(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, compressed)
    end)

    assert_raise Jason.DecodeError, fn -> Eatsbot.Geocoding.query("compressed") end
    assert Eatsbot.GeocodingStore.get_cached("compressed") == :error
  end

  test "geocoding rejects redirects without forwarding the provider token" do
    parent = self()

    serve(fn conn ->
      case conn.request_path do
        "/" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/destination")
          |> Plug.Conn.send_resp(302, "")

        _ ->
          send(parent, :redirect_followed)
          Plug.Conn.send_resp(conn, 200, "[]")
      end
    end)

    assert_raise Eatsbot.Geocoding.ProviderError, fn -> Eatsbot.Geocoding.query("redirect") end
    refute_received :redirect_followed
    assert Eatsbot.GeocodingStore.get_cached("redirect") == :error
  end

  test "geocoding rejects provider failures without caching" do
    serve(fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert_raise Eatsbot.Geocoding.ProviderError, fn -> Eatsbot.Geocoding.query("http-error") end
    assert Eatsbot.GeocodingStore.get_cached("http-error") == :error
  end

  test "geocoding rejects malformed JSON without caching" do
    serve(fn conn -> Plug.Conn.send_resp(conn, 200, "{invalid-json") end)
    assert_raise Jason.DecodeError, fn -> Eatsbot.Geocoding.query("invalid-json") end
    assert Eatsbot.GeocodingStore.get_cached("invalid-json") == :error
  end

  test "Req escapes hostile multipart names, filenames and content types" do
    url =
      serve(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, body)
      end)

    response =
      Req.post!(url,
        decode_body: false,
        retry: false,
        form_multipart: [
          {"field\"\r\nInjected: yes",
           {"value",
            filename: "file\"\r\nInjected: yes", content_type: "text/plain\r\nInjected: yes"}}
        ]
      )

    refute response.body =~ "\r\nInjected: yes"
    assert response.body =~ "field%22%0D%0AInjected: yes"
    assert response.body =~ "file%22%0D%0AInjected: yes"
  end

  defp serve(handler) do
    pid = start_supervised!({Bandit, plug: {Provider, handler}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}/"
    Application.put_env(:eatsbot, :geocoding_endpoint, url)
    url
  end
end
