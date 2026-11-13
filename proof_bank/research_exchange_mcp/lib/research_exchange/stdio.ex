defmodule ResearchExchange.Stdio do
  @moduledoc "Bounded newline JSON-RPC transport with explicit local backend selection."
  alias ResearchExchange.{Durable, Evidence, MCP, Server}
  @max_line 131_072
  def main do
    :ok = :io.setopts(:standard_io, encoding: :unicode)
    # Operator-owned configuration is outside the repository and is never read
    # from MCP arguments. The launcher must protect both this file and its env.
    raw = System.fetch_env!("RESEARCH_EXCHANGE_CONFIG") |> File.read!() |> :json.decode()
    {server, backend} = start_server(raw)
    token = System.fetch_env!("RESEARCH_EXCHANGE_TOKEN")
    {:ok, _} = Server.authenticate(server, token)
    loop(MCP.new(server, token, backend))
  end

  defp start_server(%{"backend" => "durable"} = raw) do
    true = Enum.sort(Map.keys(raw)) == ["backend", "bridge_config", "python_executable"]

    {:ok, server} =
      Durable.start_link(%{
        config_path: raw["bridge_config"],
        python_executable: raw["python_executable"]
      })

    {server, :durable}
  end

  defp start_server(%{"durable_database" => database} = raw) do
    # The merged offline pilot keeps its existing configuration and semantics.
    # Mixed selectors must not silently choose a different acceptance profile.
    true = Enum.sort(Map.keys(raw)) == ["durable_database", "receipt_key_base64"]
    {:ok, server} = Durable.start_link(database, Base.decode64!(raw["receipt_key_base64"]))
    {server, :durable_pilot}
  end

  defp start_server(raw) when is_map(raw) do
    true = Map.get(raw, "backend", "memory") == "memory"

    config = %{
      libraries: raw["libraries"],
      receipt_key: Base.decode64!(raw["receipt_key_base64"]),
      worker_key: Base.decode64!(raw["worker_key_base64"]),
      meter_key: Base.decode64!(raw["meter_key_base64"]),
      tokens:
        Map.new(raw["tokens"], fn {h, g} ->
          {h,
           %{
             principal: g["principal"],
             expires: g["expires"],
             libraries: g["libraries"],
             scopes: g["scopes"]
           }}
        end)
    }

    {:ok, server} = Server.start_link(config)
    {server, :memory}
  end

  defp loop(s) do
    case line([], 0) do
      :eof ->
        :ok

      :too_large ->
        emit(MCP.error(nil, -32600, "Message exceeds 128 KiB"))

      :invalid_encoding ->
        emit(MCP.error(nil, -32700, "Invalid UTF-8 input"))

      {:ok, bytes} ->
        {response, next} = decode(s, bytes)
        if response, do: emit(response)
        loop(next)
    end
  end

  defp line(acc, count) do
    # The standard IO device decodes Unicode. binread/binwrite ask it to
    # translate Latin-1 and either reject or corrupt non-ASCII UTF-8. Read one
    # character, retain its exact UTF-8 encoding, and enforce the bound in bytes.
    case IO.read(:stdio, 1) do
      :eof ->
        if count == 0, do: :eof, else: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

      "\n" ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

      x when is_binary(x) and count + byte_size(x) <= @max_line ->
        line([x | acc], count + byte_size(x))

      x when is_binary(x) ->
        :too_large

      _ ->
        :invalid_encoding
    end
  end

  def decode(s, bytes) when byte_size(bytes) <= @max_line do
    parsed =
      try do
        # Reject duplicate object keys at every depth before dispatch.
        decoders = %{
          null: nil,
          object_push: fn key, value, acc ->
            if List.keymember?(acc, key, 0), do: raise(ArgumentError, "duplicate key")
            [{key, value} | acc]
          end
        }

        {value, _, rest} = :json.decode(bytes, :ok, decoders)
        if String.trim(rest) != "", do: raise(ArgumentError, "trailing bytes")
        {:ok, value}
      rescue
        _ -> :error
      end

    case parsed do
      {:ok, value} -> MCP.handle(s, value)
      :error -> {MCP.error(nil, -32700, "Parse error"), s}
    end
  end

  def decode(s, _), do: {MCP.error(nil, -32600, "Message exceeds 128 KiB"), s}
  defp emit(message), do: IO.write(:stdio, Evidence.canonical(message) <> "\n")
end
