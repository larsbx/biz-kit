defmodule Mix.Tasks.Coop.Task.Predecessor do
  @shortdoc "Change an ad hoc task's predecessors under chapter governance"
  @moduledoc """
  Sign one change to a reviewed predecessor list at its current version.
  Use the chapter governance seed in `HARNESS_KEYS_DIR`.

      mix coop.task.predecessor add C/T/P TASK PREDECESSOR [--server URL] [--yes]
      mix coop.task.predecessor remove C/T/P TASK PREDECESSOR [--server URL] [--yes]
  """

  use Mix.Task

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.PredecessorChanges
  alias TaskCore.Admission
  alias TaskHost.OperatorClient

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    with {opts, [operation, path, task, predecessor], []} <-
           OptionParser.parse(args, strict: [server: :string, yes: :boolean]),
         true <- operation in ~w(add remove) and Admission.segment?(task),
         {:ok, {chapter, tenant, project} = scope} <- OperatorClient.scope(path),
         {:ok, base} <- OperatorClient.server(opts),
         {:ok, signer} <- Ops.load_signer("governance"),
         url = base <> OperatorClient.project_path(scope) <> "/tasks/#{task}/predecessors",
         {:ok, %{"tenant_id" => ^tenant, "project_id" => ^project, "task_id" => ^task} = current} <-
           Client.get_signed(url, signer),
         {:ok, payload} <- PredecessorChanges.replacement(current, operation, predecessor) do
      version = current["expected_version"]
      Mix.shell().info("#{path}/#{task} at version #{version}")

      Mix.shell().info(
        "Predecessors #{inspect(current["predecessor_ids"])} to #{inspect(payload["predecessor_ids"])}"
      )

      if opts[:yes] || Mix.shell().yes?("Sign this predecessor change?") do
        expected = &PredecessorChanges.expected?(&1, chapter, payload)

        params = %{
          "expected_version" => version,
          "predecessor_id" => predecessor,
          "operation" => operation
        }

        case Client.sign_held(url, signer, expected, params) do
          {:ok, %{"event_id" => id}} -> Mix.shell().info("changed: event #{id}")
          {:error, reason} -> Mix.raise("predecessor change refused #{inspect(reason)}")
          _ -> Mix.raise("invalid predecessor acknowledgement")
        end
      else
        Mix.shell().info("predecessor change declined")
      end
    else
      {:error, reason} -> Mix.raise("predecessor change refused #{inspect(reason)}")
      _ -> Mix.raise("usage is available through mix help coop.task.predecessor")
    end
  end
end
