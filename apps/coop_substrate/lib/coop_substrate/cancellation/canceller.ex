defmodule CoopSubstrate.Cancellation.Canceller do
  @moduledoc """
  The administrator's side of cancelling a task
  (docs/architecture/2026-10-19-cancel-reopen.md), behind `mix coop.cancel`:
  show the task, then sign its `TaskCancelledByGovernanceV1` with the
  governance key only if it cancels exactly that task, with exactly that
  reason (`CoopSubstrate.Governance.Client`).
  """

  alias CoopSubstrate.Governance.Client

  @doc "The task, as the server reports it to this governance key (a signed read)."
  @spec fetch(String.t(), CoopSubstrate.Cancellation.key(), Client.signer()) ::
          {:ok, map()} | {:error, term()}
  def fetch(base, key, signer), do: Client.get_signed(url(base, key), signer)

  @spec cancel(String.t(), CoopSubstrate.Cancellation.key(), String.t(), Client.signer()) ::
          {:ok, map()} | {:error, term()}
  def cancel(base, key, reason, signer),
    do:
      Client.sign_held(url(base, key) <> "/cancellation", signer, &cancels?(&1, key, reason), %{
        "reason" => reason
      })

  @spec cancels?(map(), CoopSubstrate.Cancellation.key(), String.t()) :: boolean()
  def cancels?(core, {chapter, tenant, project, task_id}, reason) do
    core["type"] == "TaskCancelledByGovernanceV1" and core["chapter_id"] == chapter and
      Map.delete(core["payload"], "expected_version") == %{
        "tenant_id" => tenant,
        "project_id" => project,
        "task_id" => task_id,
        "reason" => reason
      }
  end

  defp url(base, {chapter, tenant, project, task_id}),
    do:
      base <>
        "/api/v1/chapters/#{Client.segment(chapter)}/tenants/#{Client.segment(tenant)}" <>
        "/projects/#{Client.segment(project)}/tasks/#{Client.segment(task_id)}"
end
