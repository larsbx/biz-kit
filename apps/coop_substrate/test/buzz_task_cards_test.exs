defmodule CoopSubstrate.Buzz.TaskCardsTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Buzz.Tasks

  @scope {"chapter-1", "tenant-1", "project-1"}

  defp task(id) do
    %{
      title: "Inspect equipment",
      state: "inbox",
      version: 1,
      definition_of_done: "Inspection report reviewed",
      definition_ref: {:bytes, <<0::256>>},
      last_event_id: id
    }
  end

  test "stable ordering and exact chapter, tenant, and project filtering" do
    state = %{
      tasks: %{
        {"chapter-1", "tenant-1", "project-1", "b"} => task("event-b"),
        {"chapter-1", "tenant-1", "project-1", "a"} => task("event-a"),
        {"chapter-2", "tenant-1", "project-1", "c"} => task("secret-chapter"),
        {"chapter-1", "tenant-2", "project-1", "d"} => task("secret-tenant"),
        {"chapter-1", "tenant-1", "project-2", "e"} => task("secret-project")
      }
    }

    assert {:ok, cards} = Tasks.cards(state, @scope)
    assert Enum.map(cards, & &1["task_id"]) == ["a", "b"]
    assert Enum.map(cards, & &1["ledger_event_id"]) == ["event-a", "event-b"]

    assert Tasks.cards(%{tasks: state.tasks |> Enum.reverse() |> Map.new()}, @scope) ==
             {:ok, cards}
  end

  test "cards expose DoD provenance and aggregate version without inventing approval" do
    state = %{tasks: %{{"chapter-1", "tenant-1", "project-1", "a"} => task("event-a")}}
    assert {:ok, [card]} = Tasks.cards(state, @scope)
    assert card["definition_of_done"] == "Inspection report reviewed"
    assert card["definition_ref"] == String.duplicate("0", 64)
    assert card["task_version"] == 1
    assert card["state"] == "inbox"
    refute Map.has_key?(card, "approved")
    refute Map.has_key?(card, "completed")
    assert state.tasks[{"chapter-1", "tenant-1", "project-1", "a"}].state == "inbox"
  end

  test "invalid and wildcard scopes fail closed" do
    for scope <- [
          nil,
          {},
          {"chapter-1", "tenant-1"},
          {"*", "tenant-1", "project-1"},
          {"chapter-1", "", "project-1"},
          {"chapter-1", "tenant/1", "project-1"},
          {"chapter-1", 123, "project-1"},
          {String.duplicate("a", 129), "tenant-1", "project-1"}
        ] do
      assert {:error, :invalid_scope} = Tasks.cards(%{tasks: %{}}, scope)
    end

    assert {:error, :invalid_scope} = Tasks.cards(nil, @scope)
  end

  test "a valid empty scope has an empty projection" do
    assert {:ok, []} = Tasks.cards(%{tasks: %{}}, @scope)
  end

  test "member declarations and reactions are not signed task proposals" do
    for input <- [
          nil,
          [],
          %{},
          %{"member" => true},
          %{"approved" => true},
          %{"author_signature_valid" => true},
          %{"reaction" => "thumbs_up"}
        ] do
      assert {:error, :not_a_task_proposal} = Tasks.propose(input)
    end
  end
end
