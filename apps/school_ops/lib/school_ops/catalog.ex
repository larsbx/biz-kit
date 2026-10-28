defmodule SchoolOps.Catalog do
  @moduledoc """
  Public K–12 curriculum and teaching-material references within SchoolOps.

  This is a curriculum catalog, not a register of learners, student grades or
  task execution state. Source IDs stay stable across content revisions.
  """

  @grade2 "curriculum/mathematics/grade-2"
  @unit @grade2 <> "/units/place-value"

  @records %{
    "C-MATH-001" => {:course, @grade2 <> "/README.md"},
    "U-MATH-001-01" => {:unit, @unit <> "/README.md"},
    "L-MATH-001-01-01" => {:lesson, @unit <> "/lessons/01-tens-and-ones.md"},
    "L-MATH-001-01-02" => {:lesson, @unit <> "/lessons/02-hundreds.md"},
    "L-MATH-001-01-03" => {:lesson, @unit <> "/lessons/03-number-forms.md"},
    "L-MATH-001-01-04" => {:lesson, @unit <> "/lessons/04-counting.md"},
    "L-MATH-001-01-05" => {:lesson, @unit <> "/lessons/05-comparison.md"},
    "L-MATH-001-01-06" => {:lesson, @unit <> "/lessons/06-unit-check.md"},
    "A-MATH-001-01" => {:assessment, "assessments/C-MATH-001/entry-check.md"},
    "A-MATH-001-02" => {:assessment, "assessments/C-MATH-001/place-value-check.md"},
    "R-KHAN-001" => {:resource, "resources/r-khan-001.md"},
    "R-KHAN-002" => {:resource, "resources/r-khan-002.md"},
    "R-KHAN-003" => {:resource, "resources/r-khan-003.md"},
    "R-KHAN-004" => {:resource, "resources/r-khan-004.md"},
    "R-KHAN-005" => {:resource, "resources/r-khan-005.md"},
    "R-KHAN-006" => {:resource, "resources/r-khan-006.md"},
    "R-KHAN-007" => {:resource, "resources/r-khan-007.md"}
  }

  @doc "Stable, public catalog IDs; never includes learner identities."
  def ids, do: @records |> Map.keys() |> Enum.sort()

  @doc "Look up a known course, unit, lesson, assessment or resource by stable ID."
  def fetch(id) when is_binary(id) do
    case Map.fetch(@records, id) do
      {:ok, {kind, path}} ->
        with {:ok, body} <- SchoolOps.read(path) do
          {:ok, %{id: id, kind: kind, path: path, body: body}}
        end

      :error ->
        {:error, :unknown_curriculum_record}
    end
  end

  def fetch(_), do: {:error, :unknown_curriculum_record}
end
