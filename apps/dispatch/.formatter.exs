[
  import_deps: [:ash, :ash_postgres, :ash_phoenix, :ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs,heex}",
    "priv/repo/seeds.exs",
    "priv/tasks/*.exs"
  ],
  line_length: 98
]
