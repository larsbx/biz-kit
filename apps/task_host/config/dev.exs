import Config

# 4001 beside dispatch's 4000: `mix phx.server` starts both (scripts/e2e-stack.sh).
config :task_host, TaskHost.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("TASK_HOST_PORT", "4001"))],
  secret_key_base: String.duplicate("dev-only-task-host-secret-", 3),
  server: true
