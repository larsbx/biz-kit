# Postgrex types module including the PostGIS extension.
#
# Section 28.2 makes PostGIS canonical from the first migration, and a
# `geography` column cannot be encoded or decoded by Postgrex's default types.
# Without this, every write of a stop position fails at the driver with
# "type `geography` can not be handled" — a failure that surfaces only when a
# position is actually stored, which is why the schema can look correct while
# the first real insert fails.
#
# Defined at compile time in its own file, as `Postgrex.Types.define/3`
# requires, and wired to the repo through `config :dispatch, Dispatch.Repo,
# types: Dispatch.PostgresTypes`.
Postgrex.Types.define(
  Dispatch.PostgresTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
