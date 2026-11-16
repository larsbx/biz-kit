defmodule TaskHost.Web.PluginBridge do
  @moduledoc """
  Stateless Streamable HTTP for the authenticated plugin tools. The public
  discovery document contains only OAuth configuration. Tool calls use the
  same request path even when the client originally discovered them elsewhere.
  """

  @behaviour Plug

  import Plug.Conn
  alias TaskHost.PluginBridge.{Auth, Tools}

  @versions ~w(2025-11-25 2025-06-18 2025-03-26)
  @max_body 16_384
  @metadata_path String.split(".well-known/oauth-protected-resource/mcp", "/")

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{path_info: path} = conn, _opts) when path in [["mcp"], @metadata_path] do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")

    with {:ok, config} <- Auth.config(),
         true <- valid_origin?(conn, config) do
      route(conn, config, path)
    else
      {:error, :disabled} -> send_resp(conn, 404, "")
      false -> send_resp(conn, 403, "")
    end
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp route(%{method: "GET"} = conn, config, @metadata_path),
    do: json(conn, 200, Auth.metadata(config))

  defp route(conn, _config, @metadata_path),
    do: conn |> put_resp_header("allow", "GET") |> send_resp(405, "")

  defp route(%{method: "POST"} = conn, config, ["mcp"]) do
    headers = get_req_header(conn, "authorization")

    with {:ok, identity} <- Auth.principal(config, headers),
         :ok <- protocol_header(conn),
         :ok <- content_type(conn),
         {:ok, raw, conn} <- read_body(conn, length: @max_body + 1, read_timeout: 2_000),
         true <- byte_size(raw) <= @max_body do
      case Jason.decode(raw) do
        {:ok, message} -> rpc(conn, message, config, headers, identity)
        {:error, _} -> rpc_error(conn, 400, nil, -32700, "Parse error")
      end
    else
      {:error, reason} when reason in [:missing_token, :invalid_token, :insufficient_scope] ->
        auth_error(conn, config, reason)

      {:error, :identity_unavailable} ->
        json(conn, 503, %{error: "identity_unavailable"})

      {:error, :unsupported_protocol} ->
        json(conn, 400, %{error: "unsupported_protocol"})

      {:error, :unsupported_media_type} ->
        json(conn, 415, %{error: "unsupported_media_type"})

      {:more, _, conn} ->
        send_resp(conn, 413, "")

      false ->
        send_resp(conn, 413, "")

      {:error, _} ->
        rpc_error(conn, 400, nil, -32600, "Invalid request")
    end
  end

  defp route(conn, _config, ["mcp"]),
    do: conn |> put_resp_header("allow", "POST") |> send_resp(405, "")

  defp rpc(
         conn,
         %{"jsonrpc" => "2.0", "id" => id, "method" => method} = message,
         config,
         headers,
         identity
       )
       when (is_binary(id) or is_integer(id)) and is_binary(method) and
              not is_map_key(message, "result") and not is_map_key(message, "error") do
    reply(conn, id, method, Map.get(message, "params", %{}), config, headers, identity)
  end

  defp rpc(conn, %{"jsonrpc" => "2.0", "method" => "notifications/" <> _} = message, _, _, _)
       when not is_map_key(message, "id") and not is_map_key(message, "result") and
              not is_map_key(message, "error"),
       do: send_resp(conn, 202, "")

  defp rpc(conn, _message, _config, _headers, _principal),
    do: rpc_error(conn, 400, nil, -32600, "Invalid request")

  defp reply(conn, id, "initialize", %{"protocolVersion" => requested}, _, _, _)
       when is_binary(requested) do
    rpc_result(conn, id, %{
      protocolVersion: if(requested in @versions, do: requested, else: hd(@versions)),
      capabilities: %{tools: %{}},
      serverInfo: %{name: "biz-kit", version: "0.2.0"}
    })
  end

  defp reply(conn, id, "ping", params, _, _, _) when is_map(params),
    do: rpc_result(conn, id, %{})

  defp reply(conn, id, "tools/list", params, _, _, _) when is_map(params),
    do: rpc_result(conn, id, %{tools: Tools.list()})

  defp reply(
         conn,
         id,
         "tools/call",
         %{"name" => name} = params,
         config,
         headers,
         {principal, _} = identity
       )
       when is_binary(name) do
    reauthenticate = fn ->
      # A token reissued for a different subject or rebound during the read
      # cannot disclose what the first principal was permitted to see.
      with {:ok, ^config} <- Auth.config(),
           {:ok, ^identity} <- Auth.principal(config, headers) do
        :ok
      else
        {:error, reason} when reason in [:identity_unavailable, :insufficient_scope] ->
          {:error, reason}

        _ ->
          {:error, :invalid_token}
      end
    end

    case Tools.call(
           name,
           Map.get(params, "arguments", %{}),
           principal,
           config.workspace_ids,
           reauthenticate
         ) do
      {:ok, result} ->
        rpc_result(conn, id, %{
          structuredContent: result,
          content: [%{type: "text", text: Jason.encode!(result)}]
        })

      {:error, reason} when reason in [:invalid_token, :insufficient_scope] ->
        auth_error(conn, config, reason)

      {:error, :identity_unavailable} ->
        json(conn, 503, %{error: "identity_unavailable"})

      {:error, :unknown_tool} ->
        rpc_error(conn, 200, id, -32602, "Unknown tool")

      {:error, :invalid_arguments} ->
        rpc_error(conn, 200, id, -32602, "Invalid tool arguments")

      {:error, reason} ->
        rpc_result(conn, id, %{
          isError: true,
          content: [%{type: "text", text: tool_error(reason)}]
        })
    end
  end

  defp reply(conn, id, method, _, _, _, _)
       when method in ~w(initialize ping tools/list tools/call),
       do: rpc_error(conn, 200, id, -32602, "Invalid params")

  defp reply(conn, id, _method, _, _, _, _),
    do: rpc_error(conn, 200, id, -32601, "Method not found")

  defp tool_error(:no_grant), do: "access_denied"
  defp tool_error(:unknown_task), do: "task_not_found"
  defp tool_error(:no_submission), do: "no_current_submission"
  defp tool_error(:no_change), do: "due_date_unchanged"
  defp tool_error(:stale_source), do: "stale_source"
  defp tool_error(:unsupported_task), do: "task_timing_unavailable"
  defp tool_error(_reason), do: "source_unavailable"

  defp auth_error(conn, config, reason) do
    status = if reason == :insufficient_scope, do: 403, else: 401

    conn
    |> put_resp_header("www-authenticate", Auth.challenge(config, reason))
    |> json(status, %{error: Atom.to_string(reason)})
  end

  defp valid_origin?(conn, config) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin == Auth.origin(config)
      _ -> false
    end
  end

  defp protocol_header(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version] when version in @versions -> :ok
      _ -> {:error, :unsupported_protocol}
    end
  end

  defp content_type(conn) do
    with [header] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _params} <- Plug.Conn.Utils.media_type(header) do
      :ok
    else
      _ -> {:error, :unsupported_media_type}
    end
  end

  defp rpc_result(conn, id, result),
    do: json(conn, 200, %{jsonrpc: "2.0", id: id, result: result})

  defp rpc_error(conn, status, id, code, message),
    do: json(conn, status, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp json(conn, status, value),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(value))
end
