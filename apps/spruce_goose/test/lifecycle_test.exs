defmodule SpruceGoose.LifecycleTest do
  @moduledoc """
  The task machine on the shared contract (`TaskCore.Lifecycle`).

  Every property here is decided, not sampled: the relations are finite, so
  the tests enumerate the whole state set and the whole relation.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Workflows
  alias SpruceGoose.Workflows.TaskState

  @machines [Workflows.Lifecycle]

  # The contract's own properties are TaskCore's tests; these are its
  # declarations here.
  for machine <- @machines do
    describe inspect(machine) do
      @machine machine

      test "is a versioned TaskCore.Lifecycle, every state reachable and able to finish" do
        assert TaskCore.Lifecycle in behaviours(@machine)
        assert is_integer(@machine.version()) and @machine.version() >= 1
        assert TaskCore.Lifecycle.violations(@machine) == []
      end
    end
  end

  describe "task lifecycle" do
    test "is exactly the relation the Task resource enforces" do
      assert Workflows.Lifecycle.version() == 1
      assert Workflows.Lifecycle.initial() == :inbox

      assert Workflows.Lifecycle.transitions() == %{
               inbox: [:proposed, :cancelled],
               proposed: [:queued, :cancelled],
               queued: [:ready, :cancelled],
               ready: [:in_progress, :cancelled],
               in_progress: [:completed, :queued, :cancelled],
               completed: [],
               cancelled: []
             }

      assert Enum.sort(Workflows.Lifecycle.terminal_states()) == [:cancelled, :completed]
    end

    test "the persisted enum is the lifecycle's state set, in declaration order" do
      assert TaskState.values() == Workflows.Lifecycle.states()

      assert Workflows.Lifecycle.states() ==
               ~w(inbox proposed queued ready in_progress completed cancelled)a
    end

    test "work under way reopens to queued, completed and cancelled are absorbing" do
      refute Workflows.Lifecycle.terminal?(:in_progress)
      assert {:ok, :queued} = Workflows.Lifecycle.transition(:in_progress, :queued)

      for terminal <- Workflows.Lifecycle.terminal_states(), to <- Workflows.Lifecycle.states() do
        assert {:error, :invalid_transition} = Workflows.Lifecycle.transition(terminal, to)
      end
    end
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
