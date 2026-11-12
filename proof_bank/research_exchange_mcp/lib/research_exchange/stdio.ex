defmodule ResearchExchange.Stdio do
  @moduledoc "Bounded newline JSON-RPC transport for local admission backends."
  alias ResearchExchange.{Durable, Evidence, MCP, Server}
  @max_line 131_072
  def main do
    # Operator-owned configuration is outside the repository and is never read
    # from MCP arguments. The launcher must protect both this file and its env.
    raw = System.fetch_env!("RESEARCH_EXCHANGE_CONFIG") |> File.read!() |> :json.decode()

    token = System.fetch_env!("RESEARCH_EXCHANGE_TOKEN")

    {backend, started} =
      case Map.fetch(raw, "durable_database") do
        {:ok, path} ->
          {:durable, Durable.start_link(path, Base.decode64!(raw["receipt_key_base64"]))}

        :error ->
          {:memory, start_memory(raw)}
      end

    {:ok, server} = started
    {:ok, _} = Server.authenticate(server, token)
    loop(MCP.new(server, token, backend))
  end

  defp start_memory(raw) do
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

    Server.start_link(config)
  end

  defp loop(s) do
    case line([], 0) do
      :eof ->
        :ok

      :too_large ->
        emit(MCP.error(nil, -32600, "Message exceeds 128 KiB"))

      {:ok, bytes} ->
        {response, next} = decode(s, bytes)
        if response, do: emit(response)
        loop(next)
    end
  end

  defp line(acc, count) do
    case IO.binread(:stdio, 1) do
      :eof -> if count == 0, do: :eof, else: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      "\n" -> {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      x when is_binary(x) and count < @max_line -> line([x | acc], count + 1)
      _ -> :too_large
    end
  end

  def decode(s, bytes) when byte_size(bytes) <= @max_line do
    parsed =
      try do
        # Reject duplicate object keys at every depth before dispatch.
        decoders = %{
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
  defp emit(message), do: IO.binwrite(:stdio, Evidence.canonical(message) <> "\n")
end
