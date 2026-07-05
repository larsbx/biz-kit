defmodule CoopSubstrate.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Crypto self-test gates boot (phase1a_plan step 3): a substrate that
    # cannot reproduce its own known-answer vectors must not run.
    case CoopSubstrate.SelfTest.run() do
      :ok ->
        children = []

        opts = [strategy: :one_for_one, name: CoopSubstrate.Supervisor]
        Supervisor.start_link(children, opts)

      {:error, reason} ->
        {:error, {:crypto_self_test_failed, reason}}
    end
  end
end
