import Config

# Bind address, port, secret_key_base and the database come from
# config/runtime.exs at boot.
config :task_host, TaskHost.Web.Endpoint, server: true
