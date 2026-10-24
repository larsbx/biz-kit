defmodule TaskCore.ExecutionTools do
  @moduledoc """
  Small generic task-read tool, authorized independently of suggestion or
  execution grants. The host authenticates principal_id, supplies fresh signed
  replay and serializes disclosure against revocation. No caller-supplied
  principal or request body can become authority. No business write tool exists.
  """

  alias TaskCore.Access, as: TaskAccess

  @fields [:title, :description, :state, :version, :definition_of_done]

  def read_task(state, authenticated_principal, request) when is_map(request) do
    cond do
      request[:principal_id] != authenticated_principal ->
        {:error, :task_access_principal_mismatch}

      request[:action] != "read" ->
        {:error, :task_access_action_mismatch}

      true ->
        with :ok <- TaskAccess.authorize(state, request) do
          key = {request.chapter_id, request.tenant_id, request.project_id, request.task_id}
          {:ok, Map.take(Map.fetch!(state.tasks, key), @fields)}
        end
    end
  end

  def read_task(_state, _principal, _request), do: {:error, :invalid_task_access_request}
end
