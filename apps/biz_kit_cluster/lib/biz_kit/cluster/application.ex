defmodule BizKit.Cluster.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args),
    do:
      Supervisor.start_link([BizKit.Cluster],
        strategy: :one_for_one,
        name: BizKit.Cluster.Supervisor
      )
end
