defmodule Mix.Tasks.Harness.Fixtures do
  @shortdoc "Publish fixtures: publish <dir> --denylist <file> --sources I-1,I-2"
  @moduledoc """
  Runbook phase 6 — one violation kills the whole set, which is the point.
  The denylist file (one literal per line) is an input only; it never enters
  the artifact.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(["publish", dir | rest]) do
    CLI.start_app()

    {opts, _, _} = OptionParser.parse(rest, strict: [denylist: :string, sources: :string])

    sources = String.split(opts[:sources] || Mix.raise("missing --sources"), ",", trim: true)

    case Ops.fixtures_publish(dir, opts[:denylist] || Mix.raise("missing --denylist"), sources) do
      {:ok, %{fixture_hash: hash}} ->
        CLI.ok("fixture_hash=#{Base.encode16(hash, case: :lower)}")

      {:error, reason} ->
        CLI.reject(reason)
    end
  end

  def run(_), do: Mix.raise("usage: mix harness.fixtures publish <dir> --denylist <file> --sources I-1,I-2")
end
