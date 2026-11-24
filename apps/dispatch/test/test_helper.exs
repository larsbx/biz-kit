# Integration tests need PostgreSQL/PostGIS; the `unit` CI gate excludes them so
# it can run without a database service.
#
# `temporal_policy` tests state what issue #296's undecided authority policy
# would require of a blocked activation. Exactly one policy can hold, so a run
# selects it explicitly: `--include temporal_policy:admission` (or `:commit`).
ExUnit.start(exclude: [:integration, :temporal_policy])

if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
  Ecto.Adapters.SQL.Sandbox.mode(Dispatch.Repo, :manual)
end
