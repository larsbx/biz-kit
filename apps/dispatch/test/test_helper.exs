# Integration tests need PostgreSQL/PostGIS; the `unit` CI gate excludes them so
# it can run without a database service.
ExUnit.start(exclude: [:integration])

if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
  Ecto.Adapters.SQL.Sandbox.mode(Dispatch.Repo, :manual)
end
