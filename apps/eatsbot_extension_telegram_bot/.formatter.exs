# The rules apps/eatsbot applied to this code before it became its own app.
[
  import_deps: [
    :ash_authentication_phoenix,
    :ash_authentication,
    :ash_graphql,
    :ash_postgres,
    :ash,
    :phoenix
  ],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
