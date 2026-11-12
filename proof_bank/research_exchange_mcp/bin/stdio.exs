root = Path.expand("..", __DIR__)

for name <- ["evidence", "ports", "server", "durable", "mcp", "stdio"] do
  Code.require_file("lib/research_exchange/#{name}.ex", root)
end

ResearchExchange.Stdio.main()
