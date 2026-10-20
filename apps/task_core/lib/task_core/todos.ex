defmodule TaskCore.Todos do
  @moduledoc """
  A task's todos: an ordered checklist an operator keeps on a task that is
  not yet finished (docs/architecture/2026-10-20-sprucegoose-salvage.md).
  Checklist state only: a todo confers no authority over the task and never
  moves it, so todo commands leave the task's `version` alone and each todo
  keeps its own.

    * add → `TaskTodoAddedV1`, after every todo it depends on;
    * revise → `TaskTodoRevisedV1`, an open todo's title and dependencies;
    * complete → `TaskTodoCompletedV1`, once, after its dependencies are
      completed or dropped;
    * drop → `TaskTodoDroppedV1`, with a reason, once no open todo depends on it.

  Dependencies name todos of the same task that were not dropped, and never
  close a cycle. A task
  completes only once every todo is completed or dropped (`finished/1`,
  which `TaskCore.Readiness` checks).
  """

  alias TaskCore.{Admission, Dag, State}

  @subject %{
    "tenant_id" => :string,
    "project_id" => :string,
    "task_id" => :string,
    "principal_id" => :string,
    "authorization_event_id" => :string,
    "todo_id" => :string
  }
  @versioned Map.put(@subject, "expected_todo_version", :int)
  @content %{"title" => :string, "depends_on" => :any}
  @types ~w(TaskTodoAddedV1 TaskTodoRevisedV1 TaskTodoCompletedV1 TaskTodoDroppedV1)
  @max_todos 64
  @max_dependencies 32
  @max_title 512

  def event_types do
    %{
      "TaskTodoAddedV1" => spec(Map.merge(@subject, @content)),
      "TaskTodoRevisedV1" => spec(Map.merge(@versioned, @content)),
      "TaskTodoCompletedV1" => spec(@versioned),
      "TaskTodoDroppedV1" => spec(Map.put(@versioned, "reason", :string))
    }
  end

  defp spec(fields) do
    %{
      required_roles: ["operator"],
      disclosure_class: :edges,
      stream: {:payload_fields, "tasks", ~w(tenant_id project_id task_id)},
      payload: %{required: fields, optional: %{}}
    }
  end

  @doc "`:ok` once every todo of `task` is completed or dropped, else `{:error, :open_todos}`."
  def finished(task) do
    if Enum.any?(todos(task), fn {_, todo} -> todo.state == "open" end),
      do: {:error, :open_todos},
      else: :ok
  end

  @doc "A task's todos in the order they were added, each with its `id`."
  def ordered(task),
    do:
      todos(task)
      |> Enum.map(fn {id, todo} -> Map.put(todo, :id, id) end)
      |> Enum.sort_by(& &1.position)

  defp todos(task), do: Map.get(task, :todos, %{})

  # -- admission ----------------------------------------------------------------

  def check(%{payload: p} = env, state, _keys) do
    with {:ok, grant} <- fetch(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- Admission.authorized(env, grant),
         {:ok, task} <- fetch(state.tasks, State.task_key(env), :unknown_task),
         :ok <- unfinished(task),
         :ok <- todo_id(p["todo_id"]),
         do: check_command(env.type, p, todos(task))
  end

  defp check_command("TaskTodoAddedV1", p, todos) do
    cond do
      Map.has_key?(todos, p["todo_id"]) -> {:error, :todo_exists}
      map_size(todos) >= @max_todos -> {:error, :too_many_todos}
      true -> content(p, nameable(todos))
    end
  end

  defp check_command("TaskTodoRevisedV1", p, todos) do
    with {:ok, _} <- open(todos, p),
         :ok <- content(p, nameable(Map.delete(todos, p["todo_id"]))) do
      graph =
        todos
        |> Map.put(p["todo_id"], %{depends_on: p["depends_on"]})
        |> Enum.map(fn {id, todo} -> %{"id" => id, "depends_on" => todo.depends_on} end)

      if match?({:ok, _}, Dag.order(graph)), do: :ok, else: {:error, :todo_cycle}
    end
  end

  defp check_command("TaskTodoCompletedV1", p, todos) do
    with {:ok, todo} <- open(todos, p) do
      if Enum.all?(todo.depends_on, &(todos[&1].state != "open")),
        do: :ok,
        else: {:error, :todo_dependencies_open}
    end
  end

  defp check_command("TaskTodoDroppedV1", p, todos) do
    with {:ok, _} <- open(todos, p),
         :ok <- reason(p["reason"]) do
      if Enum.any?(todos, fn {_, t} -> t.state == "open" and p["todo_id"] in t.depends_on end),
        do: {:error, :todo_has_dependents},
        else: :ok
    end
  end

  # A dependency names a todo of the task that was not dropped.
  defp nameable(todos), do: Map.reject(todos, fn {_, todo} -> todo.state == "dropped" end)

  defp unfinished(%{state: state}) when state in ~w(completed cancelled),
    do: {:error, :task_finished}

  defp unfinished(_task), do: :ok

  defp open(todos, %{"todo_id" => id, "expected_todo_version" => expected}) do
    case todos[id] do
      nil -> {:error, :unknown_todo}
      %{state: "open", version: ^expected} = todo -> {:ok, todo}
      %{state: "open", version: version} -> {:error, {:stale_todo_version, expected, version}}
      _ -> {:error, :todo_not_open}
    end
  end

  # A self-dependency is a cycle; any other unknown or repeated dependency,
  # or an empty title, is malformed. `others` are the todos it may name.
  defp content(%{"title" => title, "depends_on" => deps, "todo_id" => id}, others) do
    cond do
      not (is_binary(title) and String.trim(title) != "" and String.length(title) <= @max_title) ->
        {:error, :invalid_todo}

      is_list(deps) and id in deps ->
        {:error, :todo_cycle}

      is_list(deps) and length(deps) <= @max_dependencies and Enum.uniq(deps) == deps and
          Enum.all?(deps, &Map.has_key?(others, &1)) ->
        :ok

      true ->
        {:error, :invalid_todo}
    end
  end

  defp todo_id(id), do: if(Admission.segment?(id), do: :ok, else: {:error, :invalid_todo})

  defp reason(text) do
    if is_binary(text) and String.trim(text) != "" and String.length(text) <= 2048,
      do: :ok,
      else: {:error, :invalid_reason}
  end

  defp fetch(map, id, reason) do
    case Map.fetch(map, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end

  # -- fold -----------------------------------------------------------------------

  def handle_event(%{type: type, payload: p} = env, state) when type in @types do
    update_in(state, [:tasks, State.task_key(env)], fn task ->
      Map.put(task, :todos, fold(todos(task), type, p))
    end)
  end

  def handle_event(_env, state), do: state

  defp fold(todos, "TaskTodoAddedV1", p),
    do:
      Map.put(todos, p["todo_id"], %{
        title: p["title"],
        depends_on: p["depends_on"],
        state: "open",
        version: 1,
        position: map_size(todos),
        principal_id: p["principal_id"],
        reason: nil
      })

  defp fold(todos, "TaskTodoRevisedV1", p),
    do: update(todos, p, %{title: p["title"], depends_on: p["depends_on"]})

  defp fold(todos, "TaskTodoCompletedV1", p),
    do: update(todos, p, %{state: "completed", principal_id: p["principal_id"]})

  defp fold(todos, "TaskTodoDroppedV1", p),
    do:
      update(todos, p, %{state: "dropped", principal_id: p["principal_id"], reason: p["reason"]})

  defp update(todos, p, changes),
    do:
      Map.update!(
        todos,
        p["todo_id"],
        &(&1 |> Map.merge(changes) |> Map.update!(:version, fn v -> v + 1 end))
      )
end
