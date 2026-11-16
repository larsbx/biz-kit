# Serve the end-to-end stack (scripts/e2e-stack.sh): what `mix phx.server`
# did, except the legacy eatsbot apps, which the rebuilt eatsbot
# (restaurant_host, from STATE_DIR/restaurant.json) replaces.
#
#   mix run --no-start --no-halt scripts/e2e-serve.exs STATE_DIR

[state] = System.argv()

legacy = ~w(eatsbot eatsbot_core eatsbot_extension_kafka eatsbot_extension_prometheus
            eatsbot_extension_telegram_bot)a

Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

# The shared config points Localize at the legacy eatsbot's locale cache; with
# eatsbot gone, use Localize's bundled locale, as the `restaurant` release does
# (config/runtime.exs).
Application.put_env(:localize, :otp_app, :localize, persistent: true)

Application.put_env(
  :restaurant_host,
  :restaurant_file,
  Path.join(Path.expand(state), "restaurant.json"),
  persistent: true
)

for app <- Mix.Project.apps_paths() |> Map.keys() |> Enum.sort(), app not in legacy do
  case Application.ensure_all_started(app) do
    {:ok, _} -> :ok
    {:error, reason} -> raise "#{app} did not start: #{inspect(reason)}"
  end
end

started = Application.started_applications() |> Enum.map(&elem(&1, 0))
if Enum.any?(legacy, &(&1 in started)), do: raise("a legacy eatsbot app started")
IO.puts("stack serving without legacy eatsbot")
