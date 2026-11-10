import Config

# Loopback-only test endpoint; not started unless a test asks for it.
config :task_host, :start_endpoint, false

config :task_host, TaskHost.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: String.duplicate("test-only-secret-key-base-", 4)

test_env = fn name, default ->
  case System.get_env(name) do
    value when is_binary(value) and value != "" -> value
    _ -> default
  end
end

config :task_host, TaskHost.Repo,
  database: test_env.("TASK_HOST_TEST_DATABASE", "task_host_test"),
  username: test_env.("TASK_HOST_TEST_DATABASE_USERNAME", "postgres"),
  hostname: test_env.("TASK_HOST_TEST_DATABASE_HOSTNAME", "localhost"),
  pool_size: 5

case System.get_env("TASK_HOST_TEST_DATABASE_PASSWORD") || System.get_env("PGPASSWORD") do
  value when is_binary(value) and value != "" ->
    config :task_host, TaskHost.Repo, password: value

  _ ->
    :ok
end

# Short, so the change feed's idle path (tick and heartbeat) runs in tests.
config :task_host, :feed_heartbeat_ms, 200
config :task_host, :secure_cookies, false

# Every request in the suite comes from loopback; RateLimitTest sets its own.
config :task_host, TaskHost.Web.RateLimit,
  limits: %{
    sign_in: {1_000_000, 60_000},
    capability: {1_000_000, 60_000},
    api: {1_000_000, 60_000}
  }
