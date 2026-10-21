defmodule BizKit.Identity.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Malformed bindings refuse boot: a guess about who someone is would hand
    # them a principal's authority.
    case BizKit.Identity.Resolver.check() do
      :ok ->
        Supervisor.start_link(
          [
            {BizKit.Cluster.Singleton, BizKit.Identity.Sessions},
            {BizKit.Cluster.Singleton, BizKit.Identity.NativeLogins}
          ],
          strategy: :one_for_one,
          name: BizKit.Identity.Supervisor
        )

      {:error, reason} ->
        {:error, reason}
    end
  end
end
