defmodule ProcurementHost.Application do
  @moduledoc "Private pilot console. Disabled unless explicitly configured; no default credentials."
  use Application
  def start(_type, _args) do
    children = if System.get_env("PROCUREMENT_ENABLED") == "true" do
      settings = ProcurementHost.Auth.from_env!()
      Application.put_env(:procurement_host, :settings, settings)
      [{Bandit, plug: ProcurementHost.Web, ip: {127, 0, 0, 1},
        port: String.to_integer(System.get_env("PROCUREMENT_PORT", "4080"))}]
    else
      []
    end
    Supervisor.start_link(children, strategy: :one_for_one, name: ProcurementHost.Supervisor)
  end
end
