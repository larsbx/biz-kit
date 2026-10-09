import Config

for app <- ~w(coop_substrate dispatch spruce_goose),
    path = Path.expand("../apps/#{app}/config/runtime.exs", __DIR__),
    File.exists?(path) do
  import_config path
end
