defmodule Mix.Tasks.Coop.Task.Dependencies do
  @shortdoc "Read a task's direct dependencies with a project grant"
  @moduledoc """
  Return a task's direct edges and their defining events. The local device key
  signs a read under one current project grant.

      mix coop.task.dependencies C/T/P TASK --grant ID --key-id KEY --seed-file PATH
  """

  use Mix.Task

  alias TaskCore.Admission
  alias TaskHost.OperatorClient, as: Client

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    with {opts, [path, task], []} <-
           OptionParser.parse(args,
             strict: [server: :string, grant: :string, key_id: :string, seed_file: :string]
           ),
         {:ok, scope} <- Client.scope(path),
         true <- Admission.segment?(task),
         {:ok, base} <- Client.server(opts),
         {:ok, signer} <- Client.signer(opts),
         {:ok, %{"task_id" => ^task} = body} <-
           Client.get(base, scope, "/tasks/#{task}/dependencies", signer) do
      Mix.shell().info(Jason.encode!(body))
    else
      {:error, reason} -> Mix.raise("dependency read refused #{inspect(reason)}")
      {:ok, _} -> Mix.raise("dependency response did not match the requested task")
      _ -> Mix.raise("usage is available through mix help coop.task.dependencies")
    end
  end
end
