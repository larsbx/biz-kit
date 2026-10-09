defmodule Mix.Tasks.Harness.Instrument do
  @shortdoc "Instrument: publish [tree.json] | fetch <version> | diff <v1> <v2>"
  @moduledoc """
  Runbook 0.4. `publish` with no file publishes the corpus 11 §4-D seed
  tree; question changes are new versions, diffable — your own
  leading-question drift is auditable.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Instrument
  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @chapter "chapter-genesis"

  @impl true
  def run(args) do
    CLI.start_app()

    case args do
      ["publish" | rest] ->
        tree =
          case rest do
            [] -> Instrument.seed_d()
            [path] -> path |> File.read!() |> Jason.decode!()
          end

        case Ops.instrument_publish(tree) do
          {:ok, %{version: v, tree_hash: hash}} ->
            CLI.ok("published section=#{tree["section"]} version=#{v} tree_hash=#{hex(hash)}")

          {:error, reason} ->
            CLI.reject(reason)
        end

      ["fetch", version] ->
        case Instrument.fetch(@chapter, "D", String.to_integer(version)) do
          {:ok, tree} -> CLI.ok(Jason.encode!(tree, pretty: true))
          {:error, reason} -> CLI.reject(reason)
        end

      ["diff", v1, v2] ->
        with {:ok, a} <- Instrument.fetch(@chapter, "D", String.to_integer(v1)),
             {:ok, b} <- Instrument.fetch(@chapter, "D", String.to_integer(v2)) do
          diff = Instrument.diff(a, b)
          CLI.ok("added=#{inspect(diff.added)} removed=#{inspect(diff.removed)} changed=#{inspect(diff.changed)}")
        else
          {:error, reason} -> CLI.reject(reason)
        end

      _ ->
        Mix.raise("usage: mix harness.instrument publish [tree.json] | fetch <v> | diff <v1> <v2>")
    end
  end

  defp hex(hash), do: Base.encode16(hash, case: :lower)
end
