defmodule BizOpsKB.Workflows do
  @moduledoc """
  Reviewable workflow adaptations of the verified knowledge snapshot.

  A preview verifies the actual schema-2 manifest, both original procedures,
  and a retained SOP bundle. The bundle includes the exact source revision,
  paths and bytes; its digest is part of the blueprint's readiness contract.
  Reading or downloading these artifacts neither adopts nor runs a workflow.

  The host must authorize every reader. Source selection for adoption is
  separate: governance verifies this manifest at an explicit Git commit and
  signs its application through the existing blueprint command.
  """

  alias BizOpsKB.Catalog
  alias TaskCore.Blueprint

  @id "office-assistant-onboarding-v1"
  @version "1.0.0"
  @project "office-assistant"
  @roadmap "office-setup"
  @workflow "office-onboarding"
  @inputs [{"source_24_12", "24.12"}, {"source_24_12d", "24.12d"}]
  @max_bytes 1_048_576
  @summary "An eight-task adaptation of the deployment and owner sign-off procedures, from scope approval through witnessed handoff."

  @doc "Available, verified workflow previews. A broken bundle is unavailable."
  def list(%Catalog{} = catalog, opts \\ []) do
    with {:ok, preview} <- preview(catalog, @id, opts) do
      {:ok,
       [
         preview
         |> Map.take(~w(id title version))
         |> Map.put("source_document_ids", Enum.map(@inputs, &elem(&1, 1)))
         |> Map.put("task_count", length(preview["tasks"]))
       ]}
    end
  end

  @doc "The tasks, dependencies, completion criteria and exact source pins."
  def preview(catalog, id, opts \\ [])

  def preview(%Catalog{} = catalog, @id, opts) do
    with {:ok, bundle} <- load(catalog, opts) do
      {:ok,
       %{
         "id" => @id,
         "title" => bundle.workflow["name"],
         "version" => @version,
         "summary" => @summary,
         "read_only" => true,
         "sources" => Enum.map(bundle.sources, &Map.drop(&1, ~w(body links))),
         "tasks" => bundle.workflow["tasks"],
         "adoption" => %{
           "repository" => "larsbx/biz-kit",
           "path" => "apps/bizops_kb/priv/workflows/#{@id}.json",
           "project_key" => @project,
           "roadmap_key" => @roadmap,
           "workflow_id" => @workflow,
           "manifest_sha256" => digest(bundle.manifest),
           "commit_required" => true
         },
         "sop" => %{"sha256" => digest(bundle.sop), "version" => @version},
         "required_inputs" =>
           bundle.workflow["readiness_contract"]["input_digests"]
           |> Map.put("workflow_manifest", digest(bundle.manifest))
       }}
    end
  end

  def preview(%Catalog{}, _, _), do: {:error, :not_found}

  @doc "Download the exact manifest or retained SOP bytes, after verification."
  def artifact(catalog, id, kind, opts \\ [])

  def artifact(%Catalog{} = catalog, @id, kind, opts) when kind in [:manifest, :sop] do
    with {:ok, bundle} <- load(catalog, opts) do
      {suffix, type} =
        if kind == :manifest,
          do: {".json", "application/yaml"},
          else: {".sop.md", "text/markdown"}

      {:ok, %{bytes: Map.fetch!(bundle, kind), filename: @id <> suffix, content_type: type}}
    end
  end

  def artifact(%Catalog{}, _, _, _), do: {:error, :not_found}

  @doc """
  Reproduce the version-1 SOP bundle from verified originals for review.
  The manifest pins these bytes. Updating a catalog cannot silently update an
  already authored workflow: its retained bundle and source contract must agree.
  """
  def source_bundle(%Catalog{} = catalog) do
    with {:ok, sources} <- sources(catalog), do: {:ok, render_bundle(catalog.source, sources)}
  end

  defp load(catalog, opts) do
    root = Keyword.get_lazy(opts, :root, fn -> Application.app_dir(:bizops_kb, "priv") end)

    with {:ok, manifest} <- read(root, @id <> ".json"),
         {:ok, decoded} <- decode(manifest),
         {:ok, blueprint} <- Blueprint.normalize(decoded),
         {:ok, workflow} <- selected_workflow(blueprint),
         {:ok, sources} <- sources(catalog),
         {:ok, sop} <- read(root, @id <> ".sop.md"),
         true <- sop == render_bundle(catalog.source, sources),
         true <- source_contract?(workflow["readiness_contract"], sources, sop) do
      {:ok, %{manifest: manifest, workflow: workflow, sources: sources, sop: sop}}
    else
      _ -> {:error, :workflow_unavailable}
    end
  end

  defp selected_workflow(%{
         "project" => %{"key" => @project},
         "roadmaps" => [
           %{"key" => @roadmap, "workflows" => [%{"id" => @workflow} = workflow]}
         ]
       }),
       do: {:ok, workflow}

  defp selected_workflow(_), do: :error

  defp sources(catalog) do
    Enum.reduce_while(@inputs, {:ok, []}, fn {_input, id}, {:ok, documents} ->
      case Catalog.document(catalog, id) do
        {:ok, document} -> {:cont, {:ok, documents ++ [document]}}
        _ -> {:halt, {:error, :workflow_unavailable}}
      end
    end)
  end

  defp source_contract?(contract, sources, sop) when is_map(contract) do
    digests =
      Map.new(Enum.zip(@inputs, sources), fn {{input, _}, doc} -> {input, doc["sha256"]} end)

    contract == %{
      "schema_version" => 1,
      "sop_digest" => digest(sop),
      "sop_version" => @version,
      "input_digests" => digests,
      "manifest_input" => "workflow_manifest"
    }
  end

  defp source_contract?(_, _, _), do: false

  defp render_bundle(source, sources) do
    header = """
    # Office assistant onboarding: retained SOP bundle

    Bundle format: bizops-kb-sop/1
    Workflow: #{@id}
    SOP version: #{@version}
    Source repository: #{source["repository"]}
    Source commit: #{source["revision"]}
    Source tree: #{source["tree"]}

    This bundle preserves both original procedures below, including their original
    product names and historical assumptions. Owner Part A must confirm the current
    engagement, approved stack, scope, data handling and responsible people before
    setup. Companion procedures are references to review for that engagement.
    Reading this bundle or adopting its workflow does not authorize deployment.
    Completion requires evidence and the existing signed task review process.

    """

    header <>
      Enum.map_join(sources, "\n", fn doc ->
        """
        ## Source #{doc["id"]}: #{doc["title"]}

        Original path: #{doc["path"]}
        SHA-256: #{doc["sha256"]}
        Git blob: #{doc["blob_sha"]}
        Original bytes: #{doc["size"]}

        <!-- BEGIN ORIGINAL SOURCE #{doc["id"]} -->
        """ <>
          doc["body"] <> "\n<!-- END ORIGINAL SOURCE #{doc["id"]} -->\n"
      end)
  end

  # Paths are a fixed allowlist, never caller-controlled. A Mix priv symlink is
  # allowed; the workflows directory and files beneath it must be regular.
  defp read(root, filename) when is_binary(root) do
    directory = Path.join(root, "workflows")
    path = Path.join(directory, filename)

    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, %{type: :regular, size: size}} when size in 1..@max_bytes <- File.lstat(path),
         {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)),
         true <- byte_size(bytes) == size and String.valid?(bytes) do
      {:ok, bytes}
    else
      _ -> {:error, :workflow_unavailable}
    end
  end

  defp read(_, _), do: {:error, :workflow_unavailable}

  defp decode(bytes) do
    decoders = [
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        if Map.has_key?(acc, key), do: throw(:duplicate_key), else: Map.put(acc, key, value)
      end,
      object_finish: fn acc, outer -> {acc, outer} end
    ]

    case JSON.decode(bytes, :ok, decoders) do
      {decoded, :ok, ""} -> {:ok, decoded}
      _ -> :error
    end
  catch
    :duplicate_key -> :error
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
