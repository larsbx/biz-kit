defmodule TaskHost.ProjectKnowledgeSuggestions do
  @moduledoc """
  Explainable project knowledge suggestions for an existing task or current
  workflow. The caller authorizes the exact scope before calling this module.

  Context comes from the supplied canonical state, never caller-supplied
  titles or source pins. A workflow relation requires the same adopted
  revision; an older run cannot supply procedural advice for a newer one.
  Only current approved drafts with available source artifacts are returned.
  Suggestions are references and do not change task or workflow authority.
  """

  alias TaskCore.{Blueprint, Knowledge}

  @limit 5
  @max_source_checks 20
  @stopwords MapSet.new(~w(
    a about after again all also an and any are as at be been before being by
    can completed completion confirmed criteria current definition done each
    evidence for from has have in into is it its knowledge must new of on one
    or recorded reference required review reviewed run same should step task
    tasks that the their then these this through to use used verified was
    were when which will with workflow workflows work your
  ))

  @spec select(map(), {String.t(), String.t(), String.t()}, map()) ::
          {:ok, map()} | {:error, atom()}
  def select(state, scope, context) do
    with {:ok, target} <- target(state, scope, context) do
      ranked =
        state
        |> Knowledge.candidates(scope)
        |> Enum.filter(&(&1["status"] == "approved" and &1["current"] == true))
        |> Enum.flat_map(&match_candidate(&1, target))
        |> Enum.sort_by(&{-&1["score"], &1["id"]})
        |> Enum.take(@max_source_checks)

      items =
        Enum.reduce_while(ranked, [], fn candidate, found ->
          found =
            if Knowledge.verify_availability(state, candidate) == :ok,
              do: [candidate | found],
              else: found

          if length(found) == @limit, do: {:halt, found}, else: {:cont, found}
        end)
        |> Enum.reverse()

      {:ok, %{"items" => items, "context" => target.public, "limit" => @limit}}
    end
  end

  defp target(state, {chapter, tenant, project}, %{"task_id" => id} = context)
       when map_size(context) == 1 and is_binary(id) do
    case state.tasks[{chapter, tenant, project, id}] do
      nil ->
        {:error, :unknown_knowledge_context}

      task ->
        {:ok,
         %{
           kind: :task,
           id: id,
           binding: workflow_binding(task[:blueprint]),
           tokens: tokens([task[:title], task[:description], criteria(task[:dod])]),
           public: %{"task_id" => id, "title" => task.title}
         }}
    end
  end

  defp target(state, scope, %{"roadmap_key" => roadmap, "workflow_id" => workflow} = context)
       when map_size(context) == 2 and is_binary(roadmap) and is_binary(workflow) do
    with %{revision: revision} <-
           get_in(state.hierarchy, [scope, :roadmaps, roadmap, :workflows, workflow]),
         %{scope: ^scope, blueprint: blueprint} <- state.blueprints[revision],
         {:ok, definition} <- Blueprint.workflow(blueprint, roadmap, workflow) do
      {:ok,
       %{
         kind: :workflow,
         id: workflow,
         binding: %{
           "revision_event_id" => revision,
           "roadmap_key" => roadmap,
           "workflow_id" => workflow
         },
         tokens:
           tokens([
             definition["name"],
             Enum.map(definition["tasks"], & &1["title"])
           ]),
         public: %{
           "roadmap_key" => roadmap,
           "workflow_id" => workflow,
           "revision_event_id" => revision,
           "title" => definition["name"]
         }
       }}
    else
      _ -> {:error, :unknown_knowledge_context}
    end
  end

  defp target(_state, _scope, _context), do: {:error, :invalid_knowledge_context}

  defp match_candidate(candidate, target) do
    source = candidate["source"]
    relation = source_binding(candidate)

    cond do
      target.kind == :task and candidate["kind"] == "completed_task" and
          source["task_id"] == target.id ->
        []

      same_workflow?(relation, target.binding) and
          relation["revision_event_id"] != target.binding["revision_event_id"] ->
        []

      same_workflow?(relation, target.binding) ->
        workflow_match(candidate, relation, target)

      true ->
        topic_match(candidate, target)
    end
  end

  defp workflow_match(%{"kind" => "adopted_workflow"} = candidate, _relation, _target),
    do: [recommend(candidate, 100, "Approved reference for this adopted workflow.")]

  defp workflow_match(candidate, relation, target) do
    if target.kind == :task and is_binary(relation["definition_id"]) and
         relation["definition_id"] == target.binding["definition_id"] do
      [recommend(candidate, 95, "From a completed run of this workflow step.")]
    else
      [recommend(candidate, 90, "From a completed run of this workflow.")]
    end
  end

  defp topic_match(candidate, target) do
    shared =
      tokens([candidate["title"], candidate["summary"]])
      |> MapSet.intersection(target.tokens)
      |> Enum.sort()

    # A single very short token is too weak to recommend operational advice.
    if length(shared) >= 2 or Enum.any?(shared, &(String.length(&1) >= 5)) do
      words = shared |> Enum.take(3) |> Enum.join(", ")

      [
        recommend(
          candidate,
          min(50, 10 + length(shared) * 5),
          "Matches this work's topic: #{words}."
        )
      ]
    else
      []
    end
  end

  defp recommend(candidate, score, reason),
    do: Map.merge(candidate, %{"score" => score, "reason" => reason})

  defp source_binding(%{"kind" => "adopted_workflow", "source" => source}),
    do: Map.take(source, ~w(revision_event_id roadmap_key workflow_id))

  defp source_binding(%{"source" => source}), do: source["blueprint"] || %{}

  defp workflow_binding(nil), do: %{}

  defp workflow_binding(blueprint),
    do:
      Map.new(~w(revision_event_id roadmap_key workflow_id definition_id)a, fn key ->
        {Atom.to_string(key), blueprint[key]}
      end)

  defp same_workflow?(left, right),
    do:
      is_binary(left["revision_event_id"]) and is_binary(right["revision_event_id"]) and
        is_binary(left["roadmap_key"]) and left["roadmap_key"] == right["roadmap_key"] and
        is_binary(left["workflow_id"]) and left["workflow_id"] == right["workflow_id"]

  defp criteria(%{criteria: criteria}), do: Enum.map(criteria, & &1["description"])
  defp criteria(_dod), do: []

  defp tokens(values) do
    values
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join(" ", &String.slice(&1, 0, 4096))
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and not MapSet.member?(@stopwords, &1)))
    |> Enum.take(512)
    |> MapSet.new()
  end
end
