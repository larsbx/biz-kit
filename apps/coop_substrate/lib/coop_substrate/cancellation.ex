defmodule CoopSubstrate.Cancellation do
  @moduledoc """
  Governance cancels a task (docs/architecture/2026-10-19-cancel-reopen.md):
  a `TaskCancelledByGovernanceV1`, from any state short of completed, signed
  with a governance key by `mix coop.cancel`. Held for `{:cancellation, key}`;
  the server signs nothing. People cancel before the work starts from their
  own devices (`Tasks.Lifecycle`).
  """

  alias CoopSubstrate.{Commands, Log}

  @type key :: {String.t(), String.t(), String.t(), String.t()}

  @doc "The task, for an administrator to judge, if `chapters` include its chapter."
  @spec fetch(key(), [String.t()]) :: {:ok, map()} | {:error, :unknown_task}
  def fetch({chapter, _, _, _} = key, chapters) do
    with true <- chapter in chapters,
         %{} = task <- Log.gate().orchestration.tasks[key] do
      {:ok, %{title: task.title, state: task.state, version: task.version}}
    else
      _ -> {:error, :unknown_task}
    end
  end

  @doc "Prepare the cancellation, to be signed by the named governance key."
  @spec prepare(key(), String.t(), String.t()) :: {:ok, Commands.pending()} | {:error, term()}
  def prepare({chapter, tenant, project, task_id} = key, reason, governance_key_id) do
    with %{} = task <- Log.gate().orchestration.tasks[key] || {:error, :unknown_task},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:cancellation, key},
        chapter,
        "TaskCancelledByGovernanceV1",
        %{
          "tenant_id" => tenant,
          "project_id" => project,
          "task_id" => task_id,
          "expected_version" => task.version,
          "reason" => reason
        },
        signer
      )
    end
  end

  @doc "Submit the governance signature for a held cancellation."
  @spec cancel(key(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def cancel(key, held_id, signature),
    do: Commands.submit({:cancellation, key}, held_id, signature)
end
