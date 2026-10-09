defmodule Mix.Tasks.Harness.Checkpoint do
  @shortdoc "Emit a checkpoint blob: [blob_path]"
  @moduledoc "Runbook phase 7 — publish the blob outside this machine."

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()
    path = List.first(args) || "checkpoint.bin"

    case Ops.checkpoint_emit(path) do
      {:ok, ^path} ->
        CLI.ok("checkpoint=#{path}")
        CLI.ok("PUBLISH #{path} OUTSIDE THIS MACHINE.")

      {:error, reason} ->
        CLI.reject(reason)
    end
  end
end
