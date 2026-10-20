defmodule TaskCore.Workflow do
  @moduledoc """
  Plan a whole workflow without storage or events. The caller chooses a
  lifecycle module and its expected version explicitly; a version number
  alone never identifies a lifecycle. Planning does not perform transitions,
  check SOPs or decide when a host checks prerequisites.

  The result is topologically ordered (ties by definition ID), with every
  dependency resolved to this run's task IDs. The source document's order is
  preserved by `Blueprint.normalize/1`; planning does not change signed data.
  The host must atomically check ID availability and persist the whole plan.
  """

  alias TaskCore.{Blueprint, Dag, Lifecycle}

  @spec plan(term(), String.t(), String.t(), map(), {module(), pos_integer()}) ::
          {:ok, [map()]} | {:error, term()}
  def plan(document, roadmap, workflow, ids, {machine, version}) do
    with {:ok, blueprint} <- Blueprint.normalize(document),
         {:ok, definition} <- find_workflow(blueprint, roadmap, workflow),
         :ok <- lifecycle(machine, version),
         :ok <- run_ids(definition["tasks"], ids),
         {:ok, ordered} <- Dag.order(definition["tasks"]) do
      {:ok,
       Enum.map(ordered, fn task ->
         Map.merge(task, %{
           "task_id" => ids[task["id"]],
           "predecessor_ids" => Enum.map(Enum.sort(task["depends_on"]), &ids[&1]),
           "state" => Atom.to_string(machine.initial()),
           "lifecycle_version" => version
         })
       end)}
    end
  end

  def plan(_document, _roadmap, _workflow, _ids, _contract),
    do: {:error, :unsupported_task_lifecycle}

  defp find_workflow(blueprint, roadmap, id) do
    case Blueprint.workflow(blueprint, roadmap, id) do
      :error -> {:error, :unknown_workflow}
      found -> found
    end
  end

  defp lifecycle(machine, version)
       when is_atom(machine) and is_integer(version) and version > 0 do
    callbacks = TaskCore.Lifecycle.behaviour_info(:callbacks)

    if Code.ensure_loaded?(machine) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(machine, name, arity) end) and
         machine.version() == version and Lifecycle.violations(machine) == [],
       do: :ok,
       else: {:error, :unsupported_task_lifecycle}
  end

  defp lifecycle(_, _), do: {:error, :unsupported_task_lifecycle}

  defp run_ids(tasks, ids) when is_map(ids) do
    values = Map.values(ids)

    if Enum.sort(Map.keys(ids)) == Enum.sort(Enum.map(tasks, & &1["id"])) and
         Enum.uniq(values) == values and Enum.all?(values, &identifier?/1),
       do: :ok,
       else: {:error, :invalid_workflow_run}
  end

  defp run_ids(_, _), do: {:error, :invalid_workflow_run}

  # The core's portable instance ID alphabet includes the ledger's existing
  # scope segments; definition IDs retain the stricter blueprint alphabet.
  defp identifier?(id),
    do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/, id)
end
