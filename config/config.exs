# Umbrella configuration: each app keeps its own config tree under apps/*/config,
# imported here in dependency order. Apps' own config.exs files import their
# per-environment files relative to themselves.
import Config

for app <- ~w(keel coop_substrate dispatch spruce_goose),
    path = Path.expand("../apps/#{app}/config/config.exs", __DIR__),
    File.exists?(path) do
  import_config path
end
