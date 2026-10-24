defmodule SchoolOpsTest do
  use ExUnit.Case, async: true

  test "bundled Grade 2 course retains its stable reference" do
    assert {:ok, course} =
             SchoolOps.read("curriculum/mathematics/grade-2/README.md")

    assert course =~ "C-MATH-001"
    assert {:ok, model} = SchoolOps.read("docs/curriculum-model.md")
    assert model =~ "O-MATH-001-001"
  end

  test "assessments and resource reviews are packaged" do
    assert {:ok, tasks} =
             SchoolOps.read("assessments/C-MATH-001/place-value-tasks-two-digit.md")

    assert String.length(tasks) > 100
    assert {:ok, _resource} = SchoolOps.read("resources/r-khan-001.md")
  end

  test "path traversal and absolute paths cannot escape the snapshot" do
    for path <- [
          "",
          "/",
          "../README.md",
          "docs/../README.md",
          "docs//README.md",
          "./README.md",
          "docs\\curriculum-model.md",
          "docs/" <> <<0>>
        ] do
      assert {:error, :invalid_path} = SchoolOps.read(path)
    end

    assert {:error, :invalid_path} = SchoolOps.read(nil)
    assert {:error, :enoent} = SchoolOps.read("does-not-exist.md")
  end
end
