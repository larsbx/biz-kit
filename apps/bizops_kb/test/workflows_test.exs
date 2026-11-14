defmodule BizOpsKB.WorkflowsTest do
  use ExUnit.Case, async: true

  alias BizOpsKB.{Catalog, Workflows}

  @root Path.expand("../priv", __DIR__)
  @id "office-assistant-onboarding-v1"
  @manifest "workflows/#{@id}.json"
  @sop "workflows/#{@id}.sop.md"

  setup do
    root = Path.join(System.tmp_dir!(), "bizops-workflow-#{System.unique_integer([:positive])}")
    File.cp_r!(@root, root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, catalog} = Catalog.load(root: root)
    %{root: root, catalog: catalog}
  end

  test "the real schema-2 workflow keeps owner approval before setup and acceptance after all work",
       w do
    assert {:ok, preview} = Workflows.preview(w.catalog, @id, root: w.root)
    assert preview["read_only"]
    assert preview["version"] == "1.0.0"
    assert length(preview["tasks"]) == 8
    assert {:ok, ordered} = TaskCore.Dag.order(preview["tasks"])
    assert hd(ordered)["id"] == "owner-scope"
    assert List.last(ordered)["id"] == "owner-acceptance"

    by_id = Map.new(preview["tasks"], &{&1["id"], &1})
    assert by_id["office-zone"]["depends_on"] == ["preflight", "discovery"]
    assert by_id["owner-acceptance"]["depends_on"] == ["staff-training", "admin-handoff"]
    assert Enum.all?(preview["tasks"], &(length(&1["definition_of_done"]) >= 2))

    assert {:ok, [summary]} = Workflows.list(w.catalog, root: w.root)
    assert summary["source_document_ids"] == ["24.12", "24.12d"]
    assert summary["task_count"] == 8
    refute Map.has_key?(summary, "tasks")
    assert preview["adoption"]["path"] == "apps/bizops_kb/priv/#{@manifest}"
    assert preview["adoption"]["commit_required"]
    refute Map.has_key?(preview["adoption"], "commit")
  end

  test "downloads preserve the manifest and both original procedures under their pinned digests",
       w do
    assert {:ok, preview} = Workflows.preview(w.catalog, @id, root: w.root)
    assert {:ok, manifest} = Workflows.artifact(w.catalog, @id, :manifest, root: w.root)
    assert {:ok, sop} = Workflows.artifact(w.catalog, @id, :sop, root: w.root)
    assert manifest.bytes == File.read!(Path.join(w.root, @manifest))
    assert sop.bytes == File.read!(Path.join(w.root, @sop))
    assert digest(manifest.bytes) == preview["adoption"]["manifest_sha256"]
    assert digest(sop.bytes) == preview["sop"]["sha256"]
    assert {:ok, regenerated} = Workflows.source_bundle(w.catalog)
    assert sop.bytes == regenerated

    for doc <- preview["sources"] do
      {:ok, original} = Catalog.document(w.catalog, doc["id"])
      assert sop.bytes =~ original["body"]
      assert sop.bytes =~ doc["path"]
      assert sop.bytes =~ doc["sha256"]
      assert doc["source_url"] =~ w.catalog.source["revision"]
      refute Map.has_key?(doc, "body")
    end

    assert sop.bytes =~ w.catalog.source["tree"]
    inputs = preview["required_inputs"]
    assert inputs["workflow_manifest"] == digest(manifest.bytes)
    assert map_size(inputs) == 3
  end

  test "changed source bytes, even with consistent catalog metadata, cannot replace the selected SOP",
       w do
    {:ok, doc} = Catalog.document(w.catalog, "24.12")
    bytes = doc["body"] <> "\nChanged source procedure.\n"
    File.write!(Path.join([w.root, "content", doc["path"]]), bytes)
    catalog_path = Path.join(w.root, "catalog.json")
    catalog = JSON.decode!(File.read!(catalog_path))

    changed =
      update_in(catalog["documents"], fn documents ->
        Enum.map(documents, fn entry ->
          if entry["id"] == doc["id"] do
            Map.merge(entry, %{
              "sha256" => digest(bytes),
              "size" => byte_size(bytes),
              "blob_sha" =>
                :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes)
                |> Base.encode16(case: :lower)
            })
          else
            entry
          end
        end)
      end)

    File.write!(catalog_path, JSON.encode!(changed))
    assert {:ok, changed_catalog} = Catalog.load(root: w.root)
    assert {:error, :workflow_unavailable} = Workflows.preview(changed_catalog, @id, root: w.root)
  end

  test "a different source revision or tree with identical document bodies also refuses", w do
    for field <- ~w(revision tree repository) do
      changed = %{w.catalog | source: Map.put(w.catalog.source, field, "changed-source")}
      assert {:error, :workflow_unavailable} = Workflows.preview(changed, @id, root: w.root)
    end
  end

  test "missing, changed and oversized retained artifacts fail closed", w do
    for path <- [@manifest, @sop] do
      full = Path.join(w.root, path)
      original = File.read!(full)

      for bytes <- ["", original <> "tampered", String.duplicate("x", 1_048_577)] do
        File.write!(full, bytes)
        assert {:error, :workflow_unavailable} = Workflows.preview(w.catalog, @id, root: w.root)

        assert {:error, :workflow_unavailable} =
                 Workflows.artifact(w.catalog, @id, :manifest, root: w.root)
      end

      File.rm!(full)
      assert {:error, :workflow_unavailable} = Workflows.list(w.catalog, root: w.root)
      File.write!(full, original)
    end
  end

  test "invalid schema, unknown fields, duplicate JSON keys and a changed contract refuse", w do
    path = Path.join(w.root, @manifest)
    original = File.read!(path)
    decoded = JSON.decode!(original)
    contract_path = ["roadmaps", Access.at(0), "workflows", Access.at(0), "readiness_contract"]

    invalid = [
      "not json",
      String.replace(
        original,
        ~s("schema_version": 2),
        ~s("schema_version": 2, "schema_version": 2),
        global: false
      ),
      JSON.encode!(Map.put(decoded, "execute", true)),
      JSON.encode!(put_in(decoded, contract_path ++ ["sop_digest"], String.duplicate("a", 64))),
      JSON.encode!(
        put_in(
          decoded,
          contract_path ++ ["input_digests", "source_24_12d"],
          String.duplicate("b", 64)
        )
      ),
      JSON.encode!(put_in(decoded, ["project", "key"], "different-project"))
    ]

    for bytes <- invalid do
      File.write!(path, bytes)
      assert {:error, :workflow_unavailable} = Workflows.preview(w.catalog, @id, root: w.root)
    end
  end

  test "symlinks and workflow IDs never select files outside the fixed allowlist", w do
    path = Path.join(w.root, @manifest)
    File.rm!(path)
    File.ln_s!(Path.join(@root, @manifest), path)
    assert {:error, :workflow_unavailable} = Workflows.preview(w.catalog, @id, root: w.root)

    for id <- ["..", "../catalog", "/etc/passwd", "C:/private", "unknown", <<255>>] do
      assert {:error, :not_found} = Workflows.preview(w.catalog, id, root: w.root)
      assert {:error, :not_found} = Workflows.artifact(w.catalog, id, :sop, root: w.root)
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
