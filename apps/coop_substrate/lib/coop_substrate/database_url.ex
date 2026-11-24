defmodule CoopSubstrate.DatabaseUrl do
  @moduledoc "A `postgres://` URL as Postgrex connection options, for the legacy-writer tasks."

  @doc "`{:ok, opts}`, or `:error` for anything but a postgres URL naming a host and database."
  def to_postgrex(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: host, path: "/" <> db} = uri
      when s in ["postgres", "postgresql"] and is_binary(host) and db != "" ->
        {user, pass} =
          case String.split(uri.userinfo || "", ":", parts: 2) do
            [u, p] -> {URI.decode(u), URI.decode(p)}
            [u] -> {URI.decode(u), nil}
          end

        {:ok,
         [hostname: host, port: uri.port || 5432, database: db, username: user, password: pass]
         |> Enum.reject(fn {_, v} -> v in [nil, ""] end)}

      _ ->
        :error
    end
  end

  def to_postgrex(_), do: :error
end
