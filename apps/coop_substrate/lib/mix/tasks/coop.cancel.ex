defmodule Mix.Tasks.Coop.Cancel do
  @shortdoc "Cancel a task: coop.cancel <CHAPTER> <TENANT> <PROJECT> <TASK> --reason TEXT [--server URL] [--yes]"
  @moduledoc """
  Cancel a task with the governance key
  (docs/architecture/2026-10-19-cancel-reopen.md), from any state short of
  completed, work under way included. People cancel a task themselves, from
  the web view, only before the work starts.

      mix coop.cancel chapter-1 tenant-1 project-1 task-7 --reason "Client withdrew" \\
        --server https://bizkit.example

  Shows the task (title and state) and, once confirmed, signs its
  `TaskCancelledByGovernanceV1` with the governance key in
  `HARNESS_KEYS_DIR` and submits it to the server. Cancelling is final.
  Does not start the application. `--server` defaults to `$BIZKIT_URL`,
  then `http://127.0.0.1:4000`.
  """

  use Mix.Task

  alias CoopSubstrate.Cancellation.Canceller
  alias CoopSubstrate.Harness.Ops

  @usage "usage: mix coop.cancel <CHAPTER> <TENANT> <PROJECT> <TASK> --reason TEXT [--server URL] [--yes]"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, _} =
      OptionParser.parse(args, strict: [server: :string, yes: :boolean, reason: :string])

    key =
      case positional do
        [chapter, tenant, project, task] -> {chapter, tenant, project, task}
        _ -> Mix.raise(@usage)
      end

    reason = opts[:reason] || Mix.raise(@usage)
    base = opts[:server] || System.get_env("BIZKIT_URL", "http://127.0.0.1:4000")

    with {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, task} <- Canceller.fetch(base, key, signer) do
      Mix.shell().info("""
      Task #{elem(key, 3)} in #{elem(key, 0)} / #{elem(key, 1)} / #{elem(key, 2)}
        title   #{task["title"]}
        state   #{task["state"]}
        reason  #{reason}
      Cancel it, signed by governance key #{signer.key_id}? This is final.
      """)

      if opts[:yes] || Mix.shell().yes?("Cancel?") do
        case Canceller.cancel(base, key, reason, signer) do
          {:ok, %{"event_id" => id}} -> Mix.shell().info("cancelled: event #{id}")
          {:error, why} -> Mix.raise("not cancelled: #{inspect(why)}")
        end
      else
        Mix.shell().info("not cancelled; nothing was signed")
      end
    else
      {:error, why} -> Mix.raise("cannot cancel: #{inspect(why)}")
    end
  end
end
