defmodule Dispatch.Repo.Migrations.GlobalOperatorCompatibility do
  @moduledoc """
  Enforces E3 across committed ACTIVE assignments sharing a global User.

  This is a transactional maintenance migration. It refuses conflicting or
  untrusted baselines instead of modifying assignment policy or lifecycle.
  The SQL files are also the disposable PostgreSQL acceptance source.
  """

  use Ecto.Migration

  @up_sql Path.expand("../e3/up.sql", __DIR__)
  @down_sql Path.expand("../e3/down.sql", __DIR__)
  @external_resource @up_sql
  @external_resource @down_sql

  def up, do: execute_statements(@up_sql)
  def down, do: execute_statements(@down_sql)

  defp execute_statements(path) do
    path
    |> File.read!()
    |> String.split(~r/^-- e3:statement\r?$/m, trim: true)
    |> Enum.each(&execute/1)
  end
end
