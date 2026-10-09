defmodule CoopSubstrate.Harness.Ops.CLI do
  @moduledoc """
  Shared plumbing for the `mix harness.*` tasks (Phase 3A): app start,
  line-oriented reporting, verbatim rejection passthrough, and the typed
  confirmation for lax-direction acts. No business logic lives here.
  """

  def start_app, do: Mix.Task.run("app.start")

  def ok(%{event_id: id, stream_id: stream}), do: Mix.shell().info("event=#{id} stream=#{stream}")
  def ok(message) when is_binary(message), do: Mix.shell().info(message)

  @doc "Print the gate's error term verbatim and abort — no translation layer to drift."
  def reject(reason) do
    Mix.shell().error("REJECTED: #{inspect(reason)}")
    Mix.raise("append rejected — the error term above names the runbook step that was skipped")
  end

  def report({:ok, result}), do: ok(result)
  def report({:error, reason}), do: reject(reason)

  @doc "Typed confirmation for lax-direction acts; `--yes` is the explicit script opt-out."
  def confirm!(prompt, opts) do
    unless opts[:yes] do
      answer = String.trim(Mix.shell().prompt("#{prompt}\nType 'confirm' to sign: ") || "")

      if answer != "confirm" do
        Mix.raise("not confirmed — nothing was signed")
      end
    end

    :ok
  end
end
