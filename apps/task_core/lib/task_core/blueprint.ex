defmodule TaskCore.Blueprint do
  @moduledoc """
  A project's hierarchy as a reviewed document: roadmaps, their workflows,
  and each workflow's task definitions, a dependency graph
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md). Pure: the host
  decodes the bytes (YAML, say); this checks the decoded document and
  returns its normal form, the exact term a ledger signs.

      schema_version: 2
      project: {key: maths, name: Year 7 maths}
      roadmaps:
        - key: autumn
          name: Autumn term
          workflows:
            - id: fractions
              name: Fractions
              tasks:
                - id: intro
                  title: Introducing fractions
                  definition_of_done:
                    - {id: worksheet, description: The worksheet, answered}
                  artifact_requirements: [worksheet]
                - id: adding
                  title: Adding fractions
                  definition_of_done: [{id: quiz, description: The quiz, passed}]
                  depends_on: [intro]

  SpruceGoose's blueprint (schema 1) is the model: the same nesting, keys and
  bounds, with two changes. A Definition of Done is a list of criteria, as
  the ledger reviews evidence per criterion, and a workflow's tasks sit
  directly under it rather than in a separately versioned definition. Its
  runner `kind` and `input` belong to an executor, not to the work, and are
  not part of this schema.

  Every key and ID is lowercase (`[a-z0-9][a-z0-9_-]*`, at most 128 bytes),
  so it is also a ledger scope segment. `depends_on` names tasks of the same
  workflow (`TaskCore.Dag`); `artifact_requirements` names the inputs a task
  needs, whose digests are bound per task when its readiness is defined.
  """

  alias TaskCore.{Dag, DoD}

  @schema_version 2
  @limits %{roadmaps: 32, workflows: 32, tasks: 64, depends_on: 32, artifact_requirements: 32}

  @typedoc "A normalized blueprint: string-keyed maps, lists, strings and integers only."
  @type t :: map()

  @doc "The blueprint schema this version reads."
  def schema_version, do: @schema_version

  @doc "Check a decoded document and return its normal form, or the first fault found."
  @spec normalize(term()) :: {:ok, t()} | {:error, String.t()}
  def normalize(%{"schema_version" => @schema_version} = doc) do
    with :ok <- exact_keys(doc, ~w(schema_version project roadmaps), [], "blueprint"),
         {:ok, project} <- project(doc["project"]),
         {:ok, roadmaps} <- list(doc["roadmaps"], :roadmaps, "blueprint roadmaps", &roadmap/1),
         :ok <- unique(roadmaps, "key", "roadmap keys") do
      {:ok, %{"schema_version" => @schema_version, "project" => project, "roadmaps" => roadmaps}}
    end
  end

  def normalize(%{"schema_version" => version}),
    do: {:error, "unsupported blueprint schema version #{inspect(version)}"}

  def normalize(_), do: {:error, "blueprint must be a mapping with a schema_version"}

  @doc "Workflow `id` of roadmap `roadmap` in a normalized blueprint, if it has one."
  @spec workflow(t(), String.t(), String.t()) :: {:ok, map()} | :error
  def workflow(blueprint, roadmap, id) do
    with %{} = r <- Enum.find(blueprint["roadmaps"], &(&1["key"] == roadmap)),
         %{} = w <- Enum.find(r["workflows"], &(&1["id"] == id)) do
      {:ok, w}
    else
      nil -> :error
    end
  end

  @doc "Every workflow of a normalized blueprint, with the key of its roadmap."
  @spec workflows(t()) :: [{String.t(), map()}]
  def workflows(blueprint),
    do: for(r <- blueprint["roadmaps"], w <- r["workflows"], do: {r["key"], w})

  defp project(%{} = p) do
    with :ok <- exact_keys(p, ~w(key name), [], "project"),
         {:ok, key} <- identifier(p["key"], "project key"),
         {:ok, name} <- name(p["name"], "project name"),
         do: {:ok, %{"key" => key, "name" => name}}
  end

  defp project(_), do: {:error, "blueprint project must be a mapping"}

  defp roadmap(%{} = r) do
    with :ok <- exact_keys(r, ~w(key name workflows), [], "roadmap"),
         {:ok, key} <- identifier(r["key"], "roadmap key"),
         {:ok, name} <- name(r["name"], "roadmap name"),
         {:ok, workflows} <- list(r["workflows"], :workflows, "roadmap workflows", &workflow/1),
         :ok <- unique(workflows, "id", "workflow ids"),
         do: {:ok, %{"key" => key, "name" => name, "workflows" => workflows}}
  end

  defp roadmap(_), do: {:error, "roadmap must be a mapping"}

  defp workflow(%{} = w) do
    with :ok <- exact_keys(w, ~w(id name tasks), [], "workflow"),
         {:ok, id} <- identifier(w["id"], "workflow id"),
         {:ok, name} <- name(w["name"], "workflow name"),
         {:ok, tasks} <- list(w["tasks"], :tasks, "workflow #{id} tasks", &task/1),
         :ok <- Dag.validate(tasks) |> prefixed("workflow #{id}"),
         do: {:ok, %{"id" => id, "name" => name, "tasks" => tasks}}
  end

  defp workflow(_), do: {:error, "workflow must be a mapping"}

  defp task(%{} = t) do
    with :ok <-
           exact_keys(
             t,
             ~w(id title definition_of_done),
             ~w(description depends_on artifact_requirements),
             "task definition"
           ),
         {:ok, id} <- identifier(t["id"], "task id"),
         {:ok, title} <- text(t["title"], 300, "task #{id} title"),
         {:ok, description} <- optional_text(t["description"], 2_000, "task #{id} description"),
         :ok <- criteria(t["definition_of_done"], id),
         {:ok, depends_on} <- names(t, "depends_on", id),
         {:ok, requirements} <- names(t, "artifact_requirements", id) do
      {:ok,
       %{
         "id" => id,
         "title" => title,
         "definition_of_done" => t["definition_of_done"],
         "depends_on" => depends_on,
         "artifact_requirements" => requirements
       }
       |> then(&if(description, do: Map.put(&1, "description", description), else: &1))}
    end
  end

  defp task(_), do: {:error, "task definition must be a mapping"}

  defp criteria(value, id) do
    case DoD.validate_criteria(value) do
      :ok -> :ok
      {:error, _} -> {:error, "task #{id} definition_of_done must be 1 to 32 criteria"}
    end
  end

  # Unique lowercase names, at most the ledger's bound for readiness.
  defp names(t, field, id) do
    values = Map.get(t, field, [])

    with true <- is_list(values) and length(values) <= @limits[String.to_existing_atom(field)],
         true <- Enum.uniq(values) == values,
         {:ok, _} <- map_ok(values, &identifier(&1, "")) do
      {:ok, values}
    else
      _ -> {:error, "task #{id} #{field} must be unique task keys, at most 32"}
    end
  end

  defp list(values, limit, label, fun) when is_list(values) and values != [] do
    if length(values) <= @limits[limit],
      do: map_ok(values, fun),
      else: {:error, "#{label} are more than #{@limits[limit]}"}
  end

  defp list(_, _, label, _), do: {:error, "#{label} must be a non-empty list"}

  defp exact_keys(value, required, optional, label) do
    keys = Map.keys(value)

    if Enum.all?(required, &(&1 in keys)) and Enum.all?(keys, &(&1 in (required ++ optional))),
      do: :ok,
      else: {:error, "#{label} has unknown or missing keys"}
  end

  defp identifier(value, label) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/, value),
      do: {:ok, value},
      else: {:error, "#{label} is invalid"}
  end

  defp identifier(_, label), do: {:error, "#{label} is invalid"}

  defp name(value, label), do: text(value, 200, label)

  defp text(value, max, label) do
    if is_binary(value) and String.trim(value) != "" and byte_size(value) <= max,
      do: {:ok, value},
      else: {:error, "#{label} is invalid"}
  end

  defp optional_text(nil, _max, _label), do: {:ok, nil}
  defp optional_text(value, max, label), do: text(value, max, label)

  defp unique(values, key, label) do
    ids = Enum.map(values, & &1[key])
    if Enum.uniq(ids) == ids, do: :ok, else: {:error, "#{label} must be unique"}
  end

  defp prefixed(:ok, _label), do: :ok
  defp prefixed({:error, message}, label), do: {:error, "#{label}: #{message}"}

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
