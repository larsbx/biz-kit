root = Path.expand("..", __DIR__)

for name <- ["evidence", "sqlite", "ports", "server", "mcp", "stdio"] do
  Code.require_file("lib/research_exchange/#{name}.ex", root)
end

ExUnit.start()
Code.require_file("adapter_test.exs", __DIR__)
Code.require_file("sqlite_test.exs", __DIR__)
