defmodule ResearchExchange.MCP do
  @moduledoc "MCP 2025-11-25 tools subset over stdio; credentials arrive out of band."
  alias ResearchExchange.{Evidence, Server}
  @protocol "2025-11-25"
  @schemas %{
    "library_discover" => [],
    "proof_submit" => [
      "idempotency_key",
      "library",
      "revision",
      "snapshot_sha256",
      "generation",
      "target",
      "artifact",
      "artifact_sha256"
    ],
    "verification_request" => ["idempotency_key", "submission_id"],
    "receipt_get" => ["id"]
  }
  def new(server, token, backend \\ :memory),
    do: %{server: server, token: token, phase: :new, backend: backend}

  def tools(backend \\ :memory) do
    for {name, keys} <- Enum.sort(@schemas) do
      properties =
        Map.new(keys, fn k ->
          {k, %{"type" => if(k == "generation", do: "integer", else: "string")}}
        end)

      %{
        "name" => name,
        "description" => description(name, backend),
        "inputSchema" => %{
          "type" => "object",
          "properties" => properties,
          "required" => keys,
          "additionalProperties" => false
        }
      }
    end
  end

  defp description("library_discover", _), do: "Discover authorized, pinned library metadata."

  defp description("proof_submit", _),
    do: "Store a bounded immutable proof artifact; does not execute it."

  defp description("verification_request", :durable),
    do: "Queue the admitted export for trusted offline replay."

  defp description("verification_request", :memory),
    do: "Reserve one in-memory verification slot; execution is disabled."

  defp description("receipt_get", _), do: "Read your canonical admission or observation receipt."

  def handle(s, message) do
    id = if is_map(message), do: Map.get(message, "id"), else: nil

    cond do
      not valid?(message) ->
        {error(nil, -32600, "Invalid Request"), s}

      Server.authenticate(s.server, s.token) |> elem(0) != :ok ->
        {if(Map.has_key?(message, "id"), do: error(id, -32001, "Unauthorized")), s}

      not Map.has_key?(message, "id") ->
        notification(s, message)

      true ->
        request(s, id, message["method"], Map.get(message, "params", %{}))
    end
  end

  defp valid?(m) when is_map(m) do
    m["jsonrpc"] == "2.0" and is_binary(m["method"]) and
      Enum.all?(Map.keys(m), &(&1 in ["jsonrpc", "id", "method", "params"])) and
      (not Map.has_key?(m, "id") or is_binary(m["id"]) or is_integer(m["id"])) and
      (not Map.has_key?(m, "params") or is_map(m["params"]))
  end

  defp valid?(_), do: false

  defp notification(%{phase: :initializing} = s, %{"method" => "notifications/initialized"}),
    do: {nil, %{s | phase: :ready}}

  defp notification(s, _), do: {nil, s}

  defp request(%{phase: :new} = s, id, "initialize", p) do
    if is_binary(p["protocolVersion"]) and is_map(p["capabilities"]) and is_map(p["clientInfo"]) and
         is_binary(p["clientInfo"]["name"]) and is_binary(p["clientInfo"]["version"]) do
      {ok(id, %{
         "protocolVersion" => @protocol,
         "capabilities" => %{"tools" => %{"listChanged" => false}},
         "serverInfo" => %{"name" => "research-exchange-bounded", "version" => "0.1.0"}
       }), %{s | phase: :initializing}}
    else
      {error(id, -32602, "Invalid initialize parameters"), s}
    end
  end

  defp request(s, id, "ping", _), do: {ok(id, %{}), s}

  defp request(%{phase: phase} = s, id, _, _) when phase != :ready,
    do: {error(id, -32002, "Initialize first"), s}

  defp request(s, id, "tools/list", p) when map_size(p) == 0,
    do: {ok(id, %{"tools" => tools(s.backend)}), s}

  defp request(s, id, "tools/call", %{"name" => name} = p)
       when map_size(p) == 1 or (map_size(p) == 2 and is_map_key(p, "arguments")) do
    case Server.call(s.server, s.token, name, Map.get(p, "arguments", %{})) do
      {:ok, result} ->
        {ok(id, %{
           "content" => [%{"type" => "text", "text" => Evidence.canonical(result)}],
           "structuredContent" => result,
           "isError" => false
         }), s}

      {:error, :unknown_tool} ->
        {error(id, -32602, "Unknown tool"), s}

      {:error, reason} ->
        {ok(id, %{
           "content" => [%{"type" => "text", "text" => to_string(reason)}],
           "isError" => true
         }), s}
    end
  end

  defp request(s, id, "tools/call", _), do: {error(id, -32602, "Invalid tool call"), s}
  defp request(s, id, _, _), do: {error(id, -32601, "Method not found"), s}
  defp ok(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  def error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
