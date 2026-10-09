defmodule Mix.Tasks.Harness.Status do
  @shortdoc "The cockpit line: gate verdict + counts + short legs [--section D]"
  @moduledoc "Runbook phases 4 and 7. Short legs are named in runbook terms."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()
    {opts, _, _} = OptionParser.parse(args, strict: [section: :string])

    case Ops.status(opts[:section] || "D") do
      {:ok, %{gate: gate, short: short} = status} ->
        CLI.ok("gate=#{gate}")

        if counts = status[:counts] do
          CLI.ok(
            "interviews=#{counts.interviews} corroborated=#{counts.corroborated} " <>
              "documents=#{counts.documents} adopted=#{counts.adopted} fixtures=#{counts.fixtures}"
          )
        end

        Enum.each(short, &CLI.ok("short: " <> &1))

      {:error, reason} ->
        CLI.reject(reason)
    end
  end
end
