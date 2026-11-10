root = Path.expand("..", __DIR__)

for name <- ["evidence", "sqlite", "ports", "server", "mcp", "stdio"] do
  Code.require_file("lib/research_exchange/#{name}.ex", root)
end

ResearchExchange.Stdio.main()
