# Serve the end-to-end stack (scripts/e2e-stack.sh): every umbrella app, with
# the rebuilt eatsbot (restaurant_host) reading STATE_DIR/restaurant.json.
#
#   mix run --no-start --no-halt scripts/e2e-serve.exs STATE_DIR

[state] = System.argv()

Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

Application.put_env(
  :restaurant_host,
  :restaurant_file,
  Path.join(Path.expand(state), "restaurant.json"),
  persistent: true
)

for app <- Mix.Project.apps_paths() |> Map.keys() |> Enum.sort() do
  case Application.ensure_all_started(app) do
    {:ok, _} -> :ok
    {:error, reason} -> raise "#{app} did not start: #{inspect(reason)}"
  end
end

IO.puts("stack serving")
