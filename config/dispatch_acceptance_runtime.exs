# Disposable test release only. Validate before the repo or endpoint can start.
import Config

unless config_env() == :test and
         System.get_env("PROCUREMENT_DISPATCH_ACCEPTANCE") == "disposable-local-postgres" and
         System.get_env("RELEASE_DISTRIBUTION") == "none" do
  raise "Dispatch acceptance requires the isolated test profile"
end

url = System.fetch_env!("DATABASE_URL")

%URI{
  scheme: "ecto",
  host: "127.0.0.1",
  port: port,
  path: "/dispatch_acceptance_" <> suffix,
  userinfo: userinfo,
  query: nil,
  fragment: nil
} = URI.parse(url)

unless port in 1..65_535 and is_binary(userinfo) and
         Regex.match?(~r/\A[0-9a-f]{12}\z/, suffix) do
  raise "Dispatch acceptance requires a freshly named loopback database"
end

config :dispatch, Dispatch.Repo, url: url, pool_size: 8

config :dispatch, DispatchWeb.Endpoint,
  secret_key_base: System.fetch_env!("DISPATCH_ACCEPTANCE_SESSION_KEY"),
  server: false
