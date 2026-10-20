# Committed, decoded blueprint data. A production host fetches the pinned
# revision and decodes its chosen format outside task_core. No network or YAML
# dependency is required to exercise the same portable contract here.
%{
  "schema_version" => 2,
  "project" => %{"key" => "maths", "name" => "Year 7 maths"},
  "roadmaps" => [
    %{
      "key" => "autumn",
      "name" => "Autumn term",
      "workflows" => [
        %{
          "id" => "fractions",
          "name" => "Fractions",
          # Deliberately reverse dependency order: a plan must sort it.
          "tasks" => [
            %{
              "id" => "adding",
              "title" => "Adding fractions",
              "definition_of_done" => [%{"id" => "quiz", "description" => "quiz, done"}],
              "depends_on" => ["intro"]
            },
            %{
              "id" => "intro",
              "title" => "Introducing fractions",
              "description" => "Halves, thirds and quarters",
              "definition_of_done" => [%{"id" => "worksheet", "description" => "worksheet, done"}],
              "artifact_requirements" => ["worksheet"]
            }
          ]
        }
      ]
    }
  ]
}
