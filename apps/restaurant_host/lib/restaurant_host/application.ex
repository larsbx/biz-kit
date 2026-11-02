defmodule RestaurantHost.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    load_restaurant!()

    children = [
      {Phoenix.PubSub, name: RestaurantHost.PubSub},
      RestaurantHost.Web.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RestaurantHost.Supervisor)
  end

  # Production names a restaurant file (config/runtime.exs); tests configure
  # `:restaurant` directly. Either way the restaurant is built now, so a bad
  # configuration stops the boot.
  defp load_restaurant! do
    with path when is_binary(path) <- Application.get_env(:restaurant_host, :restaurant_file) do
      case RestaurantHost.Config.load(path) do
        {:ok, config} ->
          Application.put_env(:restaurant_host, :restaurant, config)

        {:error, reason} ->
          raise ArgumentError, "invalid restaurant configuration: #{inspect(reason)}"
      end
    end

    if Application.get_env(:restaurant_host, :restaurant),
      do: RestaurantHost.Restaurant.current()
  end
end
