defmodule Dispatch.Repo do
  @moduledoc """
  The only authoritative operational state store (Section 19.1).

  PostGIS is canonical from the first migration (Section 28.2), so the
  extension is installed by `AshPostgres` rather than by an ad hoc migration.
  """

  use AshPostgres.Repo, otp_app: :dispatch

  @impl AshPostgres.Repo
  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext", "postgis"]
  end

  @impl AshPostgres.Repo
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
