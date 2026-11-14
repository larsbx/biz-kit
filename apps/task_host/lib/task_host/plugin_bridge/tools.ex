defmodule TaskHost.PluginBridge.Tools do
  @moduledoc """
  The plugin's closed list of TaskHost reads and non-persistent previews.
  The identity layer supplies the principal and the ledger supplies scope.
  """

  alias BizOpsKB.Catalog
  alias CoopSubstrate.{ArtifactCustody, Canonical, Log}
  alias CoopSubstrate.Feed.{Access, View}
  alias TaskCore.{Admission, Timing}
  alias TaskHost.{Operations, ProjectKnowledgeSuggestions}
  alias TaskHost.PluginBridge.Auth

  @page_size 25
  @max_offset 1_000
  @last_safe_integer 9_007_199_254_740_991
  @identifier %{type: "string", maxLength: 128, pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]*$"}
  @offset %{type: "integer", minimum: 0, maximum: @max_offset}
  @due %{
    type: ["integer", "null"],
    minimum: 0,
    maximum: @last_safe_integer,
    description: "Unix epoch milliseconds. Use null to remove the due date."
  }
  @operations "get_operations_view"
  @reference "search_business_knowledge"
  @knowledge "get_approved_task_knowledge"
  @evidence "get_task_evidence"
  @preview "preview_task_due_date"
  @definitions [
    {@operations, "List task summaries from one readable Operations workspace.",
     %{"offset" => @offset}, []},
    {@reference, "Search the pinned business reference catalog. Results are reference material.",
     %{"query" => %{type: "string", maxLength: 160}, "offset" => @offset}, ["query"]},
    {@knowledge, "Suggest reviewed, current project knowledge for an existing task.",
     %{"task_id" => @identifier}, ["task_id"]},
    {@evidence, "Read a task's current evidence submission identifiers and digests.",
     %{"task_id" => @identifier}, ["task_id"]},
    {@preview, "Preview a due-date change for human review without recording it.",
     %{
       "task_id" => @identifier,
       "expected_source_event_id" => @identifier,
       "due_ms" => @due
     }, ~w(task_id expected_source_event_id due_ms)}
  ]

  def list do
    Enum.map(@definitions, fn {name, description, properties, required} ->
      %{
        name: name,
        description: description,
        inputSchema: %{
          type: "object",
          properties: Map.put(properties, "workspace_id", @identifier),
          required: ["workspace_id" | required],
          additionalProperties: false
        },
        annotations: %{
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        },
        securitySchemes: [%{type: "oauth2", scopes: [Auth.scope()]}],
        _meta: %{securitySchemes: [%{type: "oauth2", scopes: [Auth.scope()]}]}
      }
    end)
  end

  def call(name, args, principal, allowed_workspaces, reauthenticate) do
    with :ok <- validate(name, args),
         true <- args["workspace_id"] in allowed_workspaces or {:error, :no_grant},
         config = operations_config(),
         {gate, revision} <- Log.read_snapshot(),
         {:ok, workspace, reader} <-
           Operations.workspace(gate, principal, config, args["workspace_id"]),
         result = run(name, args, gate, reader),
         :ok <- reauthenticate.(),
         :ok <- sources_available(name, args, gate, reader, result),
         {latest, latest_revision} <- Log.read_snapshot(),
         {:ok, ^workspace, _} <-
           Operations.workspace(latest, principal, operations_config(), args["workspace_id"]),
         true <- Access.live_in?(latest, reader) or {:error, :no_grant},
         true <- revision == latest_revision or {:error, :stale_source},
         {:ok, source} <- result do
      {:ok,
       %{
         "scope" => Map.take(workspace, ~w(id chapter_id tenant_id project_id)),
         "source" => source,
         "access" => "private",
         "schema_version" => 1
       }}
    else
      {:ok, _workspace, _} -> {:error, :stale_source}
      {:error, _} = error -> error
    end
  end

  defp sources_available(@knowledge, args, gate, reader, {:ok, _} = selected) do
    if run(@knowledge, args, gate, reader) == selected, do: :ok, else: {:error, :stale_source}
  end

  defp sources_available(_name, _args, _gate, _reader, _result), do: :ok

  defp run(@operations, args, gate, reader) do
    tasks =
      gate
      |> View.tasks(reader.scope)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, task} ->
        task
        |> Map.take([:title, :state, :version, :timing_version, :last_event_id, :timing])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.update("title", nil, &bounded_title/1)
        |> Map.put("task_id", id)
      end)

    {:ok,
     %{
       "kind" => "operations_tasks",
       "revision" => task_list_revision(tasks),
       "tasks" => Enum.slice(tasks, args["offset"] || 0, @page_size),
       "total" => length(tasks)
     }}
  end

  defp run(@reference, args, _gate, _reader) do
    with {:ok, catalog} <- Catalog.load() do
      {:ok,
       catalog
       |> Catalog.search(query: args["query"], offset: args["offset"] || 0, limit: @page_size)
       |> Map.merge(%{
         "kind" => "reference_catalog",
         "revision" => Catalog.summary(catalog)["source"]
       })}
    end
  end

  defp run(@knowledge, %{"task_id" => id}, gate, reader) do
    with {:ok, task} <- task(gate, reader.scope, id),
         {:ok, result} <-
           ProjectKnowledgeSuggestions.select(gate.orchestration, reader.scope, %{"task_id" => id}) do
      items =
        Enum.map(result["items"], fn candidate ->
          candidate
          |> Map.take(
            ~w(id kind title summary source source_fingerprint draft_digest review_version)
          )
          |> Map.put("approval_event_id", candidate["review"]["event_id"])
          |> Map.update!("source", &Map.drop(&1, ~w(evidence custody_receipts)))
        end)

      {:ok,
       %{"kind" => "approved_project_knowledge", "task" => revision(task, id), "items" => items}}
    end
  end

  defp run(@evidence, %{"task_id" => id}, gate, reader) do
    # Artifact custody applies its own stricter ACL before testing existence.
    with {:ok, evidence} <-
           ArtifactCustody.evidence(gate.orchestration, reader.principal_id, reader.scope, id),
         {:ok, task} <- task(gate, reader.scope, id) do
      {:ok,
       %{
         "kind" => "ledger_evidence_metadata",
         "task" => revision(task, id),
         "submission_event_id" => evidence.submission_event_id,
         "criteria" =>
           Map.new(evidence.evidence, fn {criterion, item} ->
             {criterion,
              %{
                "sha256" => Base.encode16(item.digest, case: :lower),
                "custody_receipt_id" => item.custody_receipt_id
              }}
           end)
       }}
    end
  end

  defp run(@preview, _args, _gate, %{role: role}) when role != :operator,
    do: {:error, :no_grant}

  defp run(@preview, args, gate, reader) do
    id = args["task_id"]

    with {:ok, task} <- task(gate, reader.scope, id),
         true <- task.last_event_id == args["expected_source_event_id"] or {:error, :stale_source},
         %{state: state, timing: %{} = current} when state != "cancelled" <- task,
         proposed = Map.put(current, "due_ms", args["due_ms"]),
         :ok <- Timing.timing(proposed),
         true <- current != proposed or {:error, :no_change} do
      {:ok,
       %{
         "kind" => "task_due_date_proposal",
         "status" => "unsigned_preview",
         "requires_human_review" => true,
         "task" => revision(task, id),
         "expected_timing_version" => task.timing_version,
         "current_timing" => current,
         "proposed_timing" => proposed
       }}
    else
      %{} -> {:error, :unsupported_task}
      {:error, _} = error -> error
    end
  end

  defp bounded_title(title) when is_binary(title) and byte_size(title) > 512,
    do: title |> binary_part(0, 512) |> String.replace_invalid("")

  defp bounded_title(title), do: title

  defp task_list_revision(tasks) do
    context = :crypto.hash_update(:crypto.hash_init(:sha256), "bizkit/plugin/operations-tasks/v1")

    tasks
    |> Enum.reduce(context, fn task, acc -> :crypto.hash_update(acc, Canonical.hash!(task)) end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp revision(task, id),
    do: %{"task_id" => id, "version" => task.version, "source_event_id" => task.last_event_id}

  defp task(gate, {chapter, tenant, project}, id),
    do: Map.fetch(gate.orchestration.tasks, {chapter, tenant, project, id}) |> found()

  defp found({:ok, _} = result), do: result
  defp found(:error), do: {:error, :unknown_task}

  defp operations_config,
    do: Application.get_env(:task_host, :operations, Operations.default_config())

  defp validate(name, args) when is_map(args) do
    case List.keyfind(@definitions, name, 0) do
      {_, _, optional_fields, required} ->
        required = ["workspace_id" | required]

        if Enum.all?(required, &Map.has_key?(args, &1)) and
             Enum.all?(args, fn {key, value} ->
               (key == "workspace_id" or Map.has_key?(optional_fields, key)) and
                 valid?(key, value)
             end),
           do: :ok,
           else: {:error, :invalid_arguments}

      nil ->
        {:error, :unknown_tool}
    end
  end

  defp validate(_name, _args), do: {:error, :invalid_arguments}

  defp valid?("query", value), do: is_binary(value) and byte_size(value) <= 160
  defp valid?("offset", value), do: is_integer(value) and value in 0..@max_offset

  defp valid?("due_ms", value),
    do: is_nil(value) or (is_integer(value) and value in 0..@last_safe_integer)

  defp valid?(_key, value), do: Admission.segment?(value)
end
