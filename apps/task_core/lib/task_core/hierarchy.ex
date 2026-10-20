defmodule TaskCore.Hierarchy do
  @moduledoc """
  A project's roadmaps and workflows, changed only by applying a reviewed
  blueprint, and the tasks a workflow run creates from it
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md).

    * `TaskBlueprintAppliedV1`, by governance: the exact blueprint
      (`TaskCore.Blueprint`) at a pinned source, `repository`, `commit`,
      `tree` and `path`, whose bytes the host holds under
      `manifest_digest`. Admission reads and decodes those bytes
      (`TaskCore.Host.read_blueprint/1`) and requires the signed blueprint
      to be their normal form, for this project. Each roadmap and workflow
      it names is created or renamed by key, never removed; a workflow is
      then governed by this revision. A source is applied once.
    * `TaskWorkflowInstantiatedV1`, by an operator: one run of a workflow
      under its current revision, naming a new task for every definition.
      Each task starts in the inbox with the definition's title and its
      Definition of Done already defined. Its predecessors are the run's
      tasks for the definitions it depends on, and its inputs are the names
      it requires: the readiness governance later defines for it must keep
      both, binding only the digests and the SOP (`TaskCore.Readiness`).
  """

  alias TaskCore.{Admission, Blueprint, State, TaskLifecycle, Workflow}
  alias TaskCore.Blueprint.Source

  @scope %{"tenant_id" => :string, "project_id" => :string}
  @source %{
    "repository" => :string,
    "commit" => :string,
    "tree" => :string,
    "path" => :string,
    "manifest_digest" => :hash,
    "blueprint" => :any
  }
  @run %{
    "principal_id" => :string,
    "authorization_event_id" => :string,
    "lifecycle_version" => :int,
    "revision_event_id" => :string,
    "roadmap_key" => :string,
    "workflow_id" => :string,
    "task_ids" => :any
  }

  def event_types do
    %{
      "TaskBlueprintAppliedV1" => spec("governance", @source),
      "TaskWorkflowInstantiatedV1" => spec("operator", @run)
    }
  end

  defp spec(role, fields) do
    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, "task_hierarchy", ~w(tenant_id project_id)},
      payload: %{required: Map.merge(@scope, fields), optional: %{}}
    }
  end

  def init, do: %{blueprints: %{}, hierarchy: %{}, hierarchy_commands: %{}}

  # -- admission -----------------------------------------------------------------

  def check(%{type: "TaskBlueprintAppliedV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         :ok <- source(p),
         :ok <- fresh_source(env, state),
         {:ok, decoded} <- read(state.host, elem(p["manifest_digest"], 1)),
         {:ok, blueprint} <- normal(decoded),
         true <- p["blueprint"] == blueprint or {:error, :blueprint_mismatch},
         true <-
           blueprint["project"]["key"] == p["project_id"] or
             {:error, :blueprint_project_mismatch},
         do: :ok
  end

  def check(%{type: "TaskWorkflowInstantiatedV1", payload: p} = env, state, _keys) do
    with {:ok, grant} <- fetch(state.grants, p["authorization_event_id"], :unknown_task_grant),
         :ok <- Admission.authorized(env, grant),
         true <- p["lifecycle_version"] == 1 or {:error, :unsupported_task_lifecycle},
         true <-
           not Map.has_key?(state.hierarchy_commands, env.event_id) or
             {:error, :command_already_recorded},
         {:ok, workflow} <- current_workflow(env, state),
         do: run_ids(env, workflow, state)
  end

  defp source(p) do
    case Source.normalize(p) do
      {:ok, _source} -> :ok
      error -> error
    end
  end

  # One revision per source in a project, as SpruceGoose records it.
  defp fresh_source(env, state) do
    if Enum.any?(state.blueprints, fn {_, b} ->
         {b.scope, b.source.repository, b.source.commit, b.source.path} ==
           {State.scope(env), env.payload["repository"], env.payload["commit"],
            env.payload["path"]}
       end),
       do: {:error, :blueprint_already_applied},
       else: :ok
  end

  defp read(host, digest) do
    if Code.ensure_loaded?(host) and function_exported?(host, :read_blueprint, 1),
      do: host.read_blueprint(digest),
      else: {:error, :blueprints_unsupported}
  end

  defp normal(decoded) do
    case Blueprint.normalize(decoded) do
      {:ok, blueprint} -> {:ok, blueprint}
      {:error, message} -> {:error, {:invalid_blueprint, message}}
    end
  end

  # Runs start only under the revision now governing the workflow.
  defp current_workflow(%{payload: p} = env, state) do
    path = [State.scope(env), :roadmaps, p["roadmap_key"], :workflows, p["workflow_id"]]

    with %{revision: revision} <- get_in(state.hierarchy, path) || {:error, :unknown_workflow},
         true <- revision == p["revision_event_id"] or {:error, :stale_blueprint_revision},
         do: run_workflow(state, p)
  end

  defp run_workflow(state, p) do
    blueprint = state.blueprints[p["revision_event_id"]].blueprint
    Blueprint.workflow(blueprint, p["roadmap_key"], p["workflow_id"])
  end

  defp run_ids(%{payload: p} = env, _workflow, state) do
    with {:ok, _plan} <- plan(state, p) do
      if Enum.any?(Map.values(p["task_ids"]), &Map.has_key?(state.tasks, key(env, &1))),
        do: {:error, :task_exists},
        else: :ok
    end
  end

  defp plan(state, p) do
    Workflow.plan(
      state.blueprints[p["revision_event_id"]].blueprint,
      p["roadmap_key"],
      p["workflow_id"],
      p["task_ids"],
      {TaskLifecycle, p["lifecycle_version"]}
    )
  end

  # -- fold -------------------------------------------------------------------------

  def handle_event(%{type: "TaskBlueprintAppliedV1", payload: p} = env, state) do
    blueprint = p["blueprint"]
    scope = State.scope(env)

    source = %{
      repository: p["repository"],
      commit: p["commit"],
      tree: p["tree"],
      path: p["path"],
      manifest_digest: p["manifest_digest"]
    }

    project =
      Map.get(state.hierarchy, scope, %{roadmaps: %{}})
      |> Map.put(:name, blueprint["project"]["name"])
      |> Map.update!(:roadmaps, &apply_roadmaps(&1, blueprint, env.event_id))

    state
    |> put_in([:blueprints, Access.key(env.event_id)], %{
      scope: scope,
      source: source,
      blueprint: blueprint
    })
    |> put_in([:hierarchy, Access.key(scope)], project)
  end

  def handle_event(%{type: "TaskWorkflowInstantiatedV1", payload: p} = env, state) do
    {:ok, tasks} = plan(state, p)

    tasks
    |> Enum.reduce(state, fn definition, acc ->
      task =
        env
        |> State.new_task(%{
          title: definition["title"],
          description: definition["description"],
          dod: %{
            event_id: env.event_id,
            criteria: definition["definition_of_done"],
            definition_ref: {:bytes, state.host.hash(definition["definition_of_done"])},
            submission: nil,
            review: nil
          }
        })
        |> Map.put(:blueprint, %{
          run_event_id: env.event_id,
          revision_event_id: p["revision_event_id"],
          roadmap_key: p["roadmap_key"],
          workflow_id: p["workflow_id"],
          definition_id: definition["id"],
          predecessor_ids: definition["predecessor_ids"],
          artifact_requirements: definition["artifact_requirements"]
        })

      put_in(acc, [:tasks, Access.key(key(env, definition["task_id"]))], task)
    end)
    |> put_in([:hierarchy_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_env, state), do: state

  defp apply_roadmaps(roadmaps, blueprint, revision) do
    Enum.reduce(blueprint["roadmaps"], roadmaps, fn r, acc ->
      workflows =
        Map.new(r["workflows"], &{&1["id"], %{name: &1["name"], revision: revision}})

      Map.update(
        acc,
        r["key"],
        %{name: r["name"], workflows: workflows},
        &%{&1 | name: r["name"], workflows: Map.merge(&1.workflows, workflows)}
      )
    end)
  end

  @doc """
  Whether a task's readiness keeps what its blueprint fixed: exactly its
  predecessors and the names of its inputs. A task not made from a
  blueprint has nothing to keep.
  """
  def keeps_blueprint(%{blueprint: b}, predecessor_ids, requirements) do
    if Enum.sort(predecessor_ids) == Enum.sort(b.predecessor_ids) and
         Enum.sort(Map.keys(requirements)) == Enum.sort(b.artifact_requirements),
       do: :ok,
       else: {:error, :blueprint_readiness_mismatch}
  end

  def keeps_blueprint(_task, _predecessor_ids, _requirements), do: :ok

  defp key(%{chapter_id: ch, payload: p}, task_id),
    do: {ch, p["tenant_id"], p["project_id"], task_id}

  defp fetch(map, id, error) do
    case Map.fetch(map, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end
end
