defmodule AshEventsSpike.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [AshEventsSpike.Repo]
    Supervisor.start_link(children, strategy: :one_for_one, name: AshEventsSpike.Supervisor)
  end
end
