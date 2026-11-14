defmodule BizOpsKB.CatalogTest do
  use ExUnit.Case, async: true

  alias BizOpsKB.Catalog

  @revision "8749d8db1abd3145b22c6a27da2cc49a41c303fe"
  @tree "79f146858c5d9d850df69b67294cb3fabf131bd1"
  @bundle Path.expand("../priv", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "bizops-kb-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(Path.join(root, "content"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "bundled source inventory loads with the recorded revision and all 216 Markdown files" do
    assert {:ok, catalog} = Catalog.load(root: @bundle)

    assert %{
             "total" => 216,
             "read_only" => true,
             "source" => %{"revision" => @revision, "tree" => @tree}
           } = Catalog.summary(catalog)

    assert {:ok, %{"jd_id" => "24.12a", "body" => body, "source_url" => url}} =
             Catalog.document(catalog, "24.12a")

    assert String.contains?(body, "Hermes")
    assert String.contains?(url, "/blob/#{@revision}/")
    refute String.contains?(url, " ")
    assert Catalog.search(catalog, query: "24.12a")["total"] > 0
  end

  test "search uses verified text, stable ordering, exact filters and metadata-only results", %{
    root: root
  } do
    documents = [
      {"20 Products/24 Procedures/24.12a Café admin.md", "# Café\nKeep the lantern bright.\n",
       %{"area" => "20 Products", "category" => "24 Procedures"}},
      {"10 Administration/11 People/11.41 Hiring.md", "# Hiring\nLantern intake.\n",
       %{"area" => "10 Administration", "category" => "11 People"}},
      {"20 Products/25 Inventory/25.11 Stock.md", "# Stock\nCount each lantern.\n",
       %{"area" => "20 Products", "category" => "25 Inventory"}}
    ]

    write_catalog(root, documents)
    assert {:ok, catalog} = Catalog.load(root: root)

    assert %{"total" => 3, "documents" => [first], "offset" => 0, "limit" => 1} =
             Catalog.search(catalog, query: "LANTERN", limit: 1)

    assert first["id"] == "11.41"
    refute Map.has_key?(first, "body")
    assert first["snippet"] == "Lantern intake."

    assert %{"total" => 1, "documents" => [%{"id" => "24.12a"}]} =
             Catalog.search(catalog, area: "20 Products", category: "24 Procedures")

    assert %{"total" => 3, "documents" => [%{"id" => "24.12a"}]} =
             Catalog.search(catalog, query: "lantern", offset: 1, limit: 1)

    assert %{"documents" => [], "total" => 0} = Catalog.search(catalog, area: "unknown")
    assert %{"limit" => 100, "offset" => 0} = Catalog.search(catalog, limit: 100_000, offset: -3)

    assert %{"error" => "invalid_query", "documents" => []} =
             Catalog.search(catalog, query: String.duplicate("é", 81))

    assert %{"error" => "invalid_query", "documents" => []} =
             Catalog.search(catalog, query: <<255>>)

    assert {:error, :not_found} = Catalog.document(catalog, "../../private")
  end

  test "Unicode paths and suffixed IDs retain exact provenance; wiki aliases resolve", %{
    root: root
  } do
    path = "20 Products/24 Procedures 📋/24.12a Café admin.md"

    write_catalog(root, [
      {path, "# Café\n[[24.12b Quick cards#Staff|cards]] [[missing]] [[../secret]]", %{}},
      {"20 Products/24 Procedures 📋/24.12b Quick cards.md", "# Cards\n", %{}}
    ])

    assert {:ok, catalog} = Catalog.load(root: root)
    assert {:ok, "24.12a"} = Catalog.resolve_link(catalog, path)
    assert {:ok, "24.12a"} = Catalog.resolve_link(catalog, "24.12a Café admin")
    assert {:ok, "24.12a"} = Catalog.resolve_link(catalog, "24.12a#Header|Alias")
    assert {:ok, document} = Catalog.document(catalog, "24.12a")
    assert document["path"] == path
    assert document["source_url"] =~ "%F0%9F%93%8B"

    assert %{
             "target" => "24.12b Quick cards#Staff",
             "label" => "cards",
             "document_id" => "24.12b",
             "status" => "resolved"
           } in document["links"]

    assert Enum.count(document["links"], &(&1["status"] == "not_found")) == 2
  end

  test "ambiguous filename stems refuse and full paths disambiguate", %{root: root} do
    write_catalog(root, [
      {"one/Introduction.md", "First", %{}},
      {"two/Introduction.md", "Second", %{}}
    ])

    assert {:ok, catalog} = Catalog.load(root: root)
    assert {:error, :ambiguous} = Catalog.resolve_link(catalog, "Introduction")
    assert {:ok, first} = Catalog.resolve_link(catalog, "one/Introduction.md")
    assert {:ok, %{"body" => "First"}} = Catalog.document(catalog, first)
    assert {:error, :not_found} = Catalog.resolve_link(catalog, "/one/Introduction")
    assert {:error, :not_found} = Catalog.resolve_link(catalog, "one/../two/Introduction")
    assert {:error, :not_found} = Catalog.resolve_link(catalog, "one\\Introduction")
    assert {:error, :not_found} = Catalog.resolve_link(catalog, <<255>>)
  end

  test "the imported README and storage decision have working bidirectional Markdown links" do
    assert {:ok, catalog} = Catalog.load(root: @bundle)
    decision_path = "docs/decisions/2026-10-30-source-custody-and-platform-storage.md"
    assert {:ok, readme_id} = Catalog.resolve_link(catalog, "README.md")
    assert {:ok, decision_id} = Catalog.resolve_link(catalog, decision_path)
    assert {:ok, readme} = Catalog.document(catalog, readme_id)
    assert {:ok, decision} = Catalog.document(catalog, decision_id)

    assert Enum.any?(readme["links"], fn link ->
             link["target"] == decision_path and link["document_id"] == decision_id and
               link["status"] == "resolved"
           end)

    assert %{
             "target" => "../../README.md",
             "label" => "Source authority and provenance",
             "document_id" => readme_id,
             "status" => "resolved"
           } in decision["links"]

    refute Enum.any?(decision["links"], &String.starts_with?(&1["target"], "https://"))
  end

  test "relative Markdown paths resolve only to exact in-vault members, preserving labels and fragments",
       %{
         root: root
       } do
    body = """
    # Procedure
    [Home <b>literal</b>](../../README.md#Source)
    [Encoded](./24.12b%20Other.md#Use%20it)
    [Dot path](.././team/24.12b Other.md#Raw heading)
    [Here](#Current heading)
    [[ 24.12b Other#Use it|<img src=x> ]]
    [Escape](../../../README.md)
    [Encoded escape](%2e%2e/%2e%2e/%2e%2e/README.md)
    [Absolute](/README.md)
    [Windows](C:/README.md)
    [Backslash](..\\README.md)
    [Unknown](../../missing.md)
    [Wrong directory](missing/24.12b Other.md)
    [External](https://example.invalid/reference)
    """

    write_catalog(root, [
      {"README.md", "# Source\n", %{}},
      {"guides/team/24.12a Procedure.md", body, %{}},
      {"guides/team/24.12b Other.md", "# Use it\n", %{}}
    ])

    assert {:ok, catalog} = Catalog.load(root: root)
    assert {:ok, readme_id} = Catalog.resolve_link(catalog, "README.md")
    assert {:ok, document} = Catalog.document(catalog, "24.12a")

    assert %{
             "target" => "../../README.md#Source",
             "label" => "Home <b>literal</b>",
             "document_id" => readme_id,
             "status" => "resolved"
           } in document["links"]

    for target <- ["./24.12b%20Other.md#Use%20it", ".././team/24.12b Other.md#Raw heading"] do
      assert Enum.any?(document["links"], fn link ->
               link["target"] == target and link["document_id"] == "24.12b" and
                 link["status"] == "resolved"
             end)
    end

    assert %{
             "target" => "24.12b Other#Use it",
             "label" => "<img src=x>",
             "document_id" => "24.12b",
             "status" => "resolved"
           } in document["links"]

    assert %{
             "target" => "#Current heading",
             "label" => "Here",
             "document_id" => "24.12a",
             "status" => "resolved"
           } in document["links"]

    for label <- [
          "Escape",
          "Encoded escape",
          "Absolute",
          "Windows",
          "Backslash",
          "Unknown",
          "Wrong directory"
        ] do
      assert Enum.any?(document["links"], fn link ->
               link["label"] == label and link["document_id"] == nil and
                 link["status"] == "not_found"
             end)
    end

    # The document-local normalization above does not relax the public resolver.
    assert {:error, :not_found} = Catalog.resolve_link(catalog, "../../README.md")
    refute Enum.any?(document["links"], &(&1["label"] == "External"))
  end

  test "changed content, size, SHA-256, or Git blob identity refuses the entire catalog", %{
    root: root
  } do
    path = "24.12 Procedure.md"
    original = write_catalog(root, [{path, "original", %{}}])
    File.write!(Path.join([root, "content", path]), "modified")
    assert {:error, :content_mismatch} = Catalog.load(root: root)
    File.write!(Path.join([root, "content", path]), "original")

    for {key, value} <- [
          {"size", 7},
          {"sha256", String.duplicate("0", 64)},
          {"blob_sha", String.duplicate("0", 40)}
        ] do
      manifest = put_in(original, ["documents", Access.at(0), key], value)
      write_manifest(root, manifest)
      assert {:error, :content_mismatch} = Catalog.load(root: root)
    end
  end

  test "missing bytes refuse; loaded snapshots never substitute newer filesystem bytes", %{
    root: root
  } do
    path = "24.12 Procedure.md"
    write_catalog(root, [{path, "original", %{}}])
    assert {:ok, catalog} = Catalog.load(root: root)
    File.rm!(Path.join([root, "content", path]))
    assert {:error, :content_unavailable} = Catalog.load(root: root)
    assert {:ok, %{"body" => "original"}} = Catalog.document(catalog, "24.12")
  end

  test "symlinked document, nested directory and content root refuse", %{root: root} do
    path = "nested/24.12 Procedure.md"
    original = write_catalog(root, [{path, "original", %{}}])
    file = Path.join([root, "content", path])
    other = Path.join(root, "retained.md")
    File.rename!(file, other)
    File.ln_s!(other, file)
    assert {:error, :invalid_catalog} = Catalog.load(root: root)
    File.rm!(file)
    File.rename!(other, file)

    File.rename!(Path.join(root, "content/nested"), Path.join(root, "elsewhere"))
    File.ln_s!(Path.join(root, "elsewhere"), Path.join(root, "content/nested"))
    assert {:error, :invalid_catalog} = Catalog.load(root: root)
    File.rm!(Path.join(root, "content/nested"))
    File.rename!(Path.join(root, "elsewhere"), Path.join(root, "content/nested"))

    File.rename!(Path.join(root, "content"), Path.join(root, "body"))
    File.ln_s!(Path.join(root, "body"), Path.join(root, "content"))
    write_manifest(root, original)
    assert {:error, :invalid_catalog} = Catalog.load(root: root)
  end

  test "a trusted Mix-style symlink to the priv root is supported", %{root: root} do
    real = Path.join(root, "real")
    link = Path.join(root, "build-priv")
    write_catalog(real, [{"24.12 Procedure.md", "original", %{}}])
    File.ln_s!(real, link)
    assert {:ok, catalog} = Catalog.load(root: link)
    assert {:ok, %{"body" => "original"}} = Catalog.document(catalog, "24.12")
  end

  test "duplicate IDs and paths, ambiguous JSON and malformed manifest identities refuse", %{
    root: root
  } do
    original = write_catalog(root, [{"24.12 Procedure.md", "original", %{}}])
    [document] = original["documents"]

    for manifest <- [
          %{original | "documents" => [document, %{document | "path" => "copy.md"}]},
          %{
            original
            | "documents" => [document, %{document | "id" => "24.13", "jd_id" => "24.13"}]
          },
          %{original | "revision" => "main"},
          %{original | "repository" => "../private"},
          Map.put(original, "approved", true),
          put_in(original, ["documents", Access.at(0), "jd_id"], "24.13"),
          put_in(original, ["documents", Access.at(0), "sha256"], "bad"),
          put_in(original, ["documents", Access.at(0), "id"], "24.12/secret")
        ] do
      write_manifest(root, manifest)
      assert {:error, :invalid_catalog} = Catalog.load(root: root)
    end

    File.write!(
      Path.join(root, "catalog.json"),
      "{\"schema\":0," <> String.trim_leading(JSON.encode!(original), "{")
    )

    assert {:error, :invalid_catalog} = Catalog.load(root: root)
  end

  test "noncanonical paths are rejected before filesystem access", %{root: root} do
    original = write_catalog(root, [{"24.12 Procedure.md", "original", %{}}])

    for path <- [
          "../24.12 Procedure.md",
          "/24.12 Procedure.md",
          "C:/private/secret.md",
          "one/../../secret.md",
          "one//secret.md",
          "one/./secret.md",
          "one\\secret.md",
          "one/secret\n.md",
          "one/secret\0.md"
        ] do
      write_manifest(root, put_in(original, ["documents", Access.at(0), "path"], path))
      assert {:error, :invalid_catalog} = Catalog.load(root: root)
    end
  end

  defp write_catalog(root, files) do
    documents =
      Enum.map(files, fn {path, bytes, overrides} ->
        full = Path.join([root, "content", path])
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, bytes)
        stem = Path.basename(path, ".md")

        jd =
          case Regex.run(~r/\A([0-9]{2}\.[0-9]{2}[a-z]?)(?:\s|$)/u, stem, capture: :all_but_first) do
            [id] -> id
            _ -> nil
          end

        %{
          "id" => jd || "ref-" <> String.slice(hash(:sha256, path), 0, 16),
          "jd_id" => jd,
          "title" => stem,
          "path" => path,
          "area" => "Reference",
          "category" => "General",
          "sha256" => hash(:sha256, bytes),
          "blob_sha" => hash(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes]),
          "size" => byte_size(bytes)
        }
        |> Map.merge(overrides)
      end)

    manifest = %{
      "schema" => 1,
      "repository" => "larsbx/bizops-kb",
      "revision" => @revision,
      "tree" => @tree,
      "documents" => documents
    }

    write_manifest(root, manifest)
    manifest
  end

  defp write_manifest(root, manifest),
    do: File.write!(Path.join(root, "catalog.json"), JSON.encode!(manifest))

  defp hash(algorithm, bytes), do: :crypto.hash(algorithm, bytes) |> Base.encode16(case: :lower)
end
