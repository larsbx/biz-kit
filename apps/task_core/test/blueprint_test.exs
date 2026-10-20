defmodule TaskCore.BlueprintTest do
  use ExUnit.Case, async: true

  alias TaskCore.Blueprint

  def criteria(id), do: [%{"id" => id, "description" => "#{id}, done"}]

  def doc do
    {document, _} = Code.eval_file(Path.join(__DIR__, "fixtures/curriculum.exs"))
    document
  end

  test "normalizes a curriculum: defaults filled, the author's order kept" do
    assert {:ok, blueprint} = Blueprint.normalize(doc())
    assert {:ok, ^blueprint} = Blueprint.normalize(blueprint)

    assert {:ok, %{"tasks" => [adding, intro]}} =
             Blueprint.workflow(blueprint, "autumn", "fractions")

    assert adding == %{
             "id" => "adding",
             "title" => "Adding fractions",
             "definition_of_done" => criteria("quiz"),
             "depends_on" => ["intro"],
             "artifact_requirements" => []
           }

    assert intro["description"] == "Halves, thirds and quarters"
    assert Blueprint.workflow(blueprint, "spring", "fractions") == :error
    assert [{"autumn", %{"id" => "fractions"}}] = Blueprint.workflows(blueprint)
  end

  test "refuses each malformed part, naming it" do
    task = &put_in(doc(), ["roadmaps", Access.at(0), "workflows", Access.at(0), "tasks"], &1)

    [adding, intro] =
      get_in(doc(), ["roadmaps", Access.at(0), "workflows", Access.at(0), "tasks"])

    for {document, message} <- [
          {Map.put(doc(), "schema_version", 1), "unsupported blueprint schema version 1"},
          {Map.put(doc(), "extra", true), "blueprint has unknown or missing keys"},
          {put_in(doc(), ["project", "key"], "Maths"), "project key is invalid"},
          {Map.put(doc(), "roadmaps", []), "blueprint roadmaps must be a non-empty list"},
          {Map.put(doc(), "roadmaps", List.duplicate(hd(doc()["roadmaps"]), 2)),
           "roadmap keys must be unique"},
          {task.([adding]),
           "workflow fractions: task \"adding\" depends on unknown task \"intro\""},
          {task.([
             Map.put(adding, "depends_on", ["intro"]),
             Map.put(intro, "depends_on", ["adding"])
           ]), "workflow fractions: dependency graph must be acyclic"},
          {task.([intro, Map.put(adding, "definition_of_done", "Pass the quiz")]),
           "task adding definition_of_done must be 1 to 32 criteria"},
          {task.([intro, Map.put(adding, "kind", "oban")]),
           "task definition has unknown or missing keys"},
          {task.([intro, Map.put(adding, "title", " ")]), "task adding title is invalid"},
          {task.([Map.put(intro, "artifact_requirements", ["a", "a"]), adding]),
           "task intro artifact_requirements must be unique task keys, at most 32"},
          {"schema_version: 2", "blueprint must be a mapping with a schema_version"}
        ] do
      assert Blueprint.normalize(document) == {:error, message}
    end
  end

  test "bounds a workflow's size" do
    tasks =
      for i <- 1..65,
          do: %{"id" => "t#{i}", "title" => "T", "definition_of_done" => criteria("c")}

    big = put_in(doc(), ["roadmaps", Access.at(0), "workflows", Access.at(0), "tasks"], tasks)
    assert Blueprint.normalize(big) == {:error, "workflow fractions tasks are more than 64"}
  end
end
