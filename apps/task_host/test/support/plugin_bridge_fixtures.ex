defmodule TaskHost.PluginBridgeFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import Plug.Conn
  alias TaskHost.PluginBridge.Auth
  alias TaskHost.Web.Endpoint

  @issuer "https://plugin-identity.example.test"
  @resource "https://plugin.example.test/mcp"

  def issuer, do: @issuer
  def resource, do: @resource

  def configure!(opts \\ []) do
    unless opts[:external_endpoint], do: ExUnit.Callbacks.start_supervised!(Endpoint)
    previous = Application.get_env(:task_host, :plugin_bridge)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:task_host, :plugin_bridge, previous),
        else: Application.delete_env(:task_host, :plugin_bridge)
    end)

    Application.put_env(:task_host, :plugin_bridge, %{
      resource: @resource,
      issuer: @issuer,
      introspection_url: @issuer <> "/introspect",
      client_id: "test bridge",
      client_secret: "test:secret",
      workspace_ids: opts[:workspace_ids] || ~w(warehouse foreign),
      req_options: [plug: {Req.Test, __MODULE__}]
    })
  end

  def claims(subject \\ "reader") do
    %{
      "active" => true,
      "iss" => @issuer,
      "sub" => subject,
      "aud" => [@resource],
      "scope" => Auth.scope(),
      "token_type" => "Bearer",
      "exp" => System.system_time(:second) + 300
    }
  end

  def introspect(lookup) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/introspect"
      expected = Base.encode64("test+bridge:test%3Asecret")
      assert get_req_header(conn, "authorization") == ["Basic " <> expected]

      {:ok, body, conn} = read_body(conn)
      %{"token" => token, "token_type_hint" => "access_token"} = URI.decode_query(body)
      Req.Test.json(conn, lookup.(token))
    end)
  end

  def request(method, path, headers \\ [], body \\ nil) do
    method
    |> Plug.Test.conn(path, body)
    |> then(
      &Enum.reduce(headers, &1, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    )
    |> Endpoint.call(Endpoint.init([]))
  end

  def rpc(method, params \\ %{}, token \\ "test-access", headers \\ []) do
    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: []) ++ headers

    request(
      :post,
      "/mcp",
      headers,
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: "test",
        method: method,
        params: params
      })
    )
  end

  def tool(name, args, token \\ "test-access"),
    do: rpc("tools/call", %{name: name, arguments: args}, token)

  def source(conn) do
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert %{"id" => "test", "result" => %{"structuredContent" => data, "content" => [entry]}} =
             Jason.decode!(conn.resp_body)

    assert data["access"] == "private"
    assert Jason.decode!(entry["text"]) == data
    data["source"]
  end

  def tool_error(conn) do
    assert conn.status == 200

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => error}]} = result} =
             Jason.decode!(conn.resp_body)

    refute Map.has_key?(result, "structuredContent")
    error
  end
end
