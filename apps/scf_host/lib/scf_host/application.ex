defmodule ScfHost.Application do
  @moduledoc "SCF accounting console and API. Disabled unless explicitly configured; no default credentials."
  use Application

  def start(_type, _args) do
    children =
      if System.get_env("SCF_ENABLED") == "true" do
        Application.put_env(:scf_host, :settings, ScfHost.Auth.from_env!())

        [
          {Bandit,
           plug: ScfHost.Web,
           ip: {127, 0, 0, 1},
           port: String.to_integer(System.get_env("SCF_PORT", "4090"))}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: ScfHost.Supervisor)
  end
end
