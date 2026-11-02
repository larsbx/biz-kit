defmodule RestaurantHost.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: RestaurantHost.PubSub},
      RestaurantHost.Web.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RestaurantHost.Supervisor)
  end
end
