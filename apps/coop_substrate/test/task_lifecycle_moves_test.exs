defmodule CoopSubstrate.TaskLifecycleMovesTest do
  @moduledoc """
  The ledger's lifecycle commands realize `TaskCore.TaskLifecycle` exactly:
  each move is in the relation (also checked as `TaskCore.Readiness` compiles),
  and every edge of the relation is some command's move.
  """
  use ExUnit.Case, async: true

  alias TaskCore.Readiness
  alias TaskCore.TaskLifecycle

  test "the commands' moves are exactly the lifecycle relation" do
    moved =
      for {_type, {from, to}} <- Readiness.moves(),
          state <- from,
          into: MapSet.new(),
          do: {state, to}

    relation =
      for {from, successors} <- TaskLifecycle.transitions(),
          to <- successors,
          into: MapSet.new(),
          do: {Atom.to_string(from), Atom.to_string(to)}

    assert moved == relation
  end

  test "every lifecycle command is a registered event type" do
    types = Map.keys(TaskCore.Admission.event_types())
    assert Map.keys(Readiness.moves()) -- types == []
  end

  test "a move from elsewhere is refused with the state and the target" do
    assert Readiness.move(%{state: "inbox"}, "TaskProposedV1") == :ok

    assert Readiness.move(%{state: "completed"}, "TaskReopenedV1") ==
             {:error, {:invalid_task_transition, "completed", "queued"}}

    assert Readiness.move(%{state: "in_progress"}, "TaskCancelledV1") ==
             {:error, {:invalid_task_transition, "in_progress", "cancelled"}}
  end
end
