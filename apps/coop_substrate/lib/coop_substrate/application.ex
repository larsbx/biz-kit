defmodule CoopSubstrate.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias BizKit.Cluster.Singleton

  @impl true
  def start(_type, _args) do
    # Crypto self-test gates boot (phase1a_plan step 3): a substrate that
    # cannot reproduce its own known-answer vectors must not run.
    case CoopSubstrate.SelfTest.run() do
      :ok ->
        # The appender and the in-memory stores are one per cluster
        # (docs/architecture/2026-10-19-cluster.md); every node runs the
        # event store client and the feed's notification group.
        children = [
          CoopSubstrate.EventStore,
          # Before Log, which notifies it after every append.
          CoopSubstrate.Feed,
          {Singleton, CoopSubstrate.Feed.Nonces},
          {Singleton, CoopSubstrate.Commands},
          {Singleton, CoopSubstrate.Enrolments},
          {Singleton, CoopSubstrate.Log}
        ]

        opts = [strategy: :one_for_one, name: CoopSubstrate.Supervisor]
        Supervisor.start_link(children, opts)

      {:error, reason} ->
        {:error, {:crypto_self_test_failed, reason}}
    end
  end
end
