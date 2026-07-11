defmodule Mix.Tasks.Harness.Model do
  @shortdoc "Process model: publish | show"
  @moduledoc """
  Runbook phase 5. `publish` compiles from the log (deterministic — anyone
  can recompile and byte-compare); `show` prints the latest published model.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(args) do
    CLI.start_app()

    case args do
      ["publish"] ->
        case Ops.model_publish() do
          {:ok, %{artifact_hash: hash}} ->
            CLI.ok("model_hash=#{Base.encode16(hash, case: :lower)}")

          {:error, reason} ->
            CLI.reject(reason)
        end

      ["show"] ->
        case Ops.model_show() do
          {:ok, model} -> CLI.ok(Jason.encode!(model, pretty: true))
          {:error, reason} -> CLI.reject(reason)
        end

      _ ->
        Mix.raise("usage: mix harness.model publish | show")
    end
  end
end
