defmodule Mix.Tasks.Harness.Spec do
  @shortdoc "Compile + store the spec: publish <classifier.json>"
  @moduledoc """
  Runbook phase 5. The classifier is YOUR tier judgment per core claim —
  `{\"h\": \"H1\"..\"H6\"}` ⇒ R, `\"contested\"` ⇒ N, `{\"enveloped\": true}` ⇒ A,
  anything left unclassified lands block (the safe wrong answer). Prints the
  three hashes `harness.adopt` needs.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Harness.Ops.CLI

  @impl true
  def run(["publish", classifier_path]) do
    CLI.start_app()
    classifier = classifier_path |> File.read!() |> Jason.decode!()

    case Ops.spec_publish(classifier) do
      {:ok, %{spec_hash: s, envelope_defaults_hash: e, model_hash: m}} ->
        CLI.ok("spec_hash=#{hex(s)}")
        CLI.ok("defaults_hash=#{hex(e)}")
        CLI.ok("model_hash=#{hex(m)}")

      {:error, reason} ->
        CLI.reject(reason)
    end
  end

  def run(_), do: Mix.raise("usage: mix harness.spec publish <classifier.json>")

  defp hex(hash), do: Base.encode16(hash, case: :lower)
end
