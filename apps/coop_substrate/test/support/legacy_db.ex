defmodule CoopSubstrate.LegacyDb do
  @moduledoc "A throwaway database standing in for a retired writer's, dropped on exit."

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Create it and return `{conn, postgrex_opts}`."
  def create!(prefix) do
    admin_opts =
      Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)
      |> Keyword.take([:hostname, :port, :username, :password])

    db = "#{prefix}_#{System.unique_integer([:positive])}"
    query_admin!(admin_opts, "CREATE DATABASE #{db}")
    on_exit(fn -> query_admin!(admin_opts, "DROP DATABASE IF EXISTS #{db} WITH (FORCE)") end)

    opts = Keyword.put(admin_opts, :database, db)
    {:ok, conn} = Postgrex.start_link(opts)
    {conn, opts}
  end

  @doc "The `postgres://` URL of `opts`, as the legacy-writer tasks take it."
  def url(opts) do
    "postgres://#{URI.encode_www_form(opts[:username])}:#{URI.encode_www_form(opts[:password] || "")}" <>
      "@#{opts[:hostname]}:#{opts[:port] || 5432}/#{opts[:database]}"
  end

  defp query_admin!(opts, sql) do
    {:ok, admin} = Postgrex.start_link(Keyword.put(opts, :database, "postgres"))
    Postgrex.query!(admin, sql, [])
    GenServer.stop(admin)
  end
end
