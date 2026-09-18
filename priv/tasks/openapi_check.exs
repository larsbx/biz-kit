# Fails when contracts/openapi.json differs from the generated description.
# Section 33.5 makes openapi-diff a required gate, and Section 20 makes the
# checked-in file the input to Android client generation, so drift between the
# two would silently produce a client for an API that does not exist.
{:ok, _} = Application.ensure_all_started(:open_api_spex)

path = Path.expand("../../../contracts/openapi.json", __DIR__)
generated = DispatchWeb.OpenApiJson.encode()

case File.read(path) do
  {:ok, ^generated} ->
    IO.puts("contracts/openapi.json is up to date.")

  {:ok, _stale} ->
    IO.puts(:stderr, """
    contracts/openapi.json is out of date.

    Run `mix openapi.generate` in central/ and commit the result.
    """)

    System.halt(1)

  {:error, reason} ->
    IO.puts(:stderr, "Could not read #{path}: #{:file.format_error(reason)}")
    System.halt(1)
end
