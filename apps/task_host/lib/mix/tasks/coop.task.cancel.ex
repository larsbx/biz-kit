defmodule Mix.Tasks.Coop.Task.Cancel do
  @shortdoc "Cancel a task with its chapter's governance key"
  @moduledoc """
  Review the current task and cancel it with a governance key in
  `HARNESS_KEYS_DIR`. The running task host admits the signature only while
  that task version and the chapter key are current and cancellation is legal.
  Operators may still cancel before start from their own signed session.

      mix coop.task.cancel chapter/tenant/project TASK_ID REASON [--server URL] [--yes]
  """

  use Mix.Task

  alias CoopSubstrate.Cancellation
  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops

  @usage "usage: mix coop.task.cancel CHAPTER/TENANT/PROJECT TASK_ID REASON [--server URL] [--yes]"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    with {opts, [scope, task_id, reason], []} <-
           OptionParser.parse(args, strict: [server: :string, yes: :boolean]),
         [chapter, tenant, project] = segments <- String.split(scope, "/"),
         true <- Enum.all?([task_id | segments], &(&1 != "")),
         true <- String.trim(reason) != "" do
      base = opts[:server] || Client.default_server()

      url =
        "#{String.trim_trailing(base, "/")}/api/v1/chapters/#{Client.segment(chapter)}" <>
          "/tenants/#{Client.segment(tenant)}/projects/#{Client.segment(project)}" <>
          "/tasks/#{Client.segment(task_id)}"

      case Ops.load_signer("governance") do
        {:ok, signer} -> cancel(url, signer, {chapter, tenant, project}, task_id, reason, opts)
        {:error, error} -> Mix.raise("cannot load governance key: #{inspect(error)}")
      end
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp cancel(url, signer, {chapter, tenant, project}, task_id, reason, opts) do
    with {:ok, %{"task_id" => ^task_id, "version" => version, "title" => title, "state" => state}}
         when is_integer(version) and is_binary(title) and is_binary(state) <-
           Client.get_signed(url, signer) do
      Mix.shell().info("""
      Task #{chapter}/#{tenant}/#{project}/#{task_id} (#{state}, version #{version})
      Title #{inspect(title)}
      Reason #{inspect(reason)}
      Governance key: #{signer.key_id}
      """)

      if opts[:yes] || Mix.shell().yes?("Cancel?") do
        expected =
          &Cancellation.expected?(&1, {chapter, tenant, project, task_id}, version, reason)

        case Client.sign_held(url <> "/cancellation", signer, expected, %{"reason" => reason}) do
          {:ok, %{"event_id" => event_id}} -> Mix.shell().info("cancelled: event #{event_id}")
          {:error, error} -> Mix.raise("cancellation refused: #{inspect(error)}")
          _ -> Mix.raise("task host returned an invalid cancellation acknowledgement")
        end
      else
        Mix.shell().info("cancellation declined")
      end
    else
      {:error, error} -> Mix.raise("cannot read task: #{inspect(error)}")
      _ -> Mix.raise("task host returned an invalid task")
    end
  end
end
