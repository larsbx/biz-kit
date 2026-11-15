# Umbrella configuration: each app keeps its own config tree under apps/*/config,
# imported here in dependency order. Apps' own config.exs files import their
# per-environment files relative to themselves.
import Config

for app <- ~w(keel coop_substrate dispatch spruce_goose task_host restaurant_host eatsbot),
    path = Path.expand("../apps/#{app}/config/config.exs", __DIR__),
    File.exists?(path) do
  import_config path
end

# Keep Dispatch and TaskHost credentials out of Phoenix request logs. Phoenix
# matches substrings, so "code" also covers "code_verifier".
config :phoenix, :filter_parameters, ~w(password token authorization secret code state signature)

# Narrow ledger and Dispatch jobs do not carry the legacy Eatsbot locale cache.
if config_env() == :test and System.get_env("BIZKIT_BUNDLED_TEST_LOCALE") == "true" do
  config :localize, otp_app: :localize
end
