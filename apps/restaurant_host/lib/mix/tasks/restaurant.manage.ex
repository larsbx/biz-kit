defmodule Mix.Tasks.Restaurant.Manage do
  use Mix.Task

  @shortdoc "Publish a signed restaurant menu or revoke a device"

  @impl true
  def run(args), do: RestaurantHost.Management.main(args)
end
