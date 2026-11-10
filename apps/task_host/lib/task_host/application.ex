defmodule TaskHost.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # A malformed trusted proxy stops this node here rather than failing
    # every request later.
    TaskHost.Web.RateLimit.trusted()

    children =
      [TaskHost.Repo, {BizKit.Cluster.Singleton, TaskHost.Web.RateLimit.Counts}] ++
        if(Application.get_env(:task_host, :start_endpoint, true),
          do: [TaskHost.Web.Endpoint],
          else: []
        )

    Supervisor.start_link(children, strategy: :one_for_one, name: TaskHost.Supervisor)
  end
end
