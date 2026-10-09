defmodule Mix.Tasks.Cockpit.Sweep do
  @shortdoc "The guard sweep: append the B_op breach finding if this period breached"
  @moduledoc "Exactly-once per period is the gate's guarantee — re-runs reject, harmlessly."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(_args) do
    CLI.start_app()

    case Ops.guard_sweep(System.system_time(:millisecond)) do
      {:ok, :no_breach} -> CLI.ok("no breach")
      {:ok, env} -> CLI.ok(env)
      {:error, reason} -> CLI.reject(reason)
    end
  end
end
