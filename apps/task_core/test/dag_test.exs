defmodule TaskCore.DagTest do
  use ExUnit.Case, async: true

  alias TaskCore.Dag

  defmodule Lesson do
    @moduledoc false
    defstruct [:id, depends_on: []]
  end

  test "orders a graph deterministically, ties broken by id" do
    tasks = [
      %{id: "publish", depends_on: ["verify"]},
      %{id: "capture"},
      %{id: "verify", depends_on: ["capture"]},
      %{id: "announce", depends_on: ["capture"]}
    ]

    assert {:ok, ordered} = Dag.order(tasks)
    assert Enum.map(ordered, & &1.id) == ~w(capture announce verify publish)
    assert {:ok, ^ordered} = Dag.order(Enum.reverse(tasks))
    assert Dag.validate(tasks) == :ok
  end

  test "takes structs and string keys alike" do
    assert {:ok, [%Lesson{id: "intro"}, %Lesson{id: "fractions"}]} =
             Dag.order([%Lesson{id: "fractions", depends_on: ["intro"]}, %Lesson{id: "intro"}])

    assert :ok = Dag.validate([%{"id" => "b", "depends_on" => ["a"]}, %{"id" => "a"}])
  end

  test "refuses duplicate ids, self, unknown, duplicate and cyclic dependencies" do
    for {tasks, expected} <- [
          {[%{id: "a"}, %{id: "a"}], "task ids must be unique"},
          {[%{id: "a", depends_on: ["a"]}], "cannot depend on itself"},
          {[%{id: "a", depends_on: ["missing"]}], "unknown task"},
          {[%{id: "a"}, %{id: "b", depends_on: ["a", "a"]}], "duplicate dependencies"},
          {[%{id: "a", depends_on: ["b"]}, %{id: "b", depends_on: ["a"]}], "must be acyclic"}
        ] do
      assert {:error, message} = Dag.validate(tasks)
      assert message =~ expected
    end
  end

  test "an empty graph has no work; no graph has nothing to check" do
    assert Dag.validate([]) == {:error, "must contain at least one task"}
    assert Dag.validate(nil) == :ok
  end
end
